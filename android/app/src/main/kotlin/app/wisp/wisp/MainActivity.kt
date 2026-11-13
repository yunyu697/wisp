package app.wisp.wisp

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Android 侧方法通道 `wisp/android`：
 * · 组播锁（发现服务必须持有，否则内核丢 224.0.0.167 的 announce）；
 * · 打开外链（更新弹层的下载链接过去在 Android 上是死链）；
 * · 把下载好的安装包放进系统下载目录（分区存储下只能走 MediaStore）；
 * · 拉起 APK 安装界面 / 用系统应用打开聊天附件（FileProvider 授权）。
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wisp/android")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        try {
                            if (multicastLock?.isHeld != true) {
                                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                multicastLock = wifi.createMulticastLock("wisp-discovery").apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            // 无 Wi-Fi 硬件（模拟器/纯以太网）等场景拿不到锁，
                            // 不打断发现流程——组播收不到时还有扫描兜底。
                            result.success(false)
                        }
                    }
                    "releaseMulticastLock" -> {
                        try {
                            multicastLock?.takeIf { it.isHeld }?.release()
                        } catch (_: Exception) {
                        }
                        result.success(null)
                    }
                    "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                    "saveToDownloads" -> result.success(saveToDownloads(call.argument<String>("path")))
                    "installApk" -> result.success(installApk(call.argument<String>("target")))
                    "openFile" -> result.success(openFile(call.argument<String>("path")))
                    else -> result.notImplemented()
                }
            }
    }

    /** 系统浏览器打开 http(s) 链接；没有浏览器时明确返回 false。 */
    private fun openUrl(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 把文件复制进公共 Download 目录。
     * Android 10+ 用 MediaStore.Downloads（返回的 content:// 同时用于安装），
     * Android 9 及以下直接写公共目录（权限限定 maxSdk=28）。
     */
    private fun saveToDownloads(path: String?): String? {
        if (path.isNullOrBlank()) return null
        val src = File(path)
        if (!src.exists()) return null
        val name = src.name
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "application/vnd.android.package-archive")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return null
            return try {
                val out = contentResolver.openOutputStream(uri)
                    ?: throw IllegalStateException("openOutputStream returned null")
                out.use { sink -> src.inputStream().use { input -> input.copyTo(sink) } }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                uri.toString()
            } catch (e: Exception) {
                try {
                    contentResolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
                null
            }
        }
        // Android 6.0+ 还得动态授权；没授权时先申请，并退回应用专属
        // Download 目录，保证这次下载依然有一个可安装、可被 FileProvider
        // 授权出去的产物。用户授权后，下一次下载就进系统下载目录。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            try {
                requestPermissions(
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    1001
                )
            } catch (_: Exception) {
            }
            return copyToAppDownloads(src)
        }
        return copyToPublicDownloads(src) ?: copyToAppDownloads(src)
    }

    private fun copyToPublicDownloads(src: File): String? {
        return try {
            val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if (!dir.exists()) dir.mkdirs()
            val dest = File(dir, src.name)
            src.inputStream().use { input -> dest.outputStream().use { sink -> input.copyTo(sink) } }
            dest.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    /** 应用专属 Download：不需要任何存储权限，file_paths.xml 已覆盖。 */
    private fun copyToAppDownloads(src: File): String? {
        return try {
            val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: File(filesDir, Environment.DIRECTORY_DOWNLOADS)
            if (!dir.exists()) dir.mkdirs()
            val dest = File(dir, src.name)
            src.inputStream().use { input -> dest.outputStream().use { sink -> input.copyTo(sink) } }
            dest.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    /** 拉起系统安装界面：'ok' / 'permission_required' / 'failed'。 */
    private fun installApk(target: String?): String {
        if (target.isNullOrBlank()) return "failed"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            try {
                val settings = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(settings)
            } catch (_: Exception) {
            }
            return "permission_required"
        }
        val uri = if (target.startsWith("content://")) {
            Uri.parse(target)
        } else {
            try {
                FileProvider.getUriForFile(this, "$packageName.fileprovider", File(target))
            } catch (e: Exception) {
                return "failed"
            }
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(intent)
            "ok"
        } catch (e: Exception) {
            "failed"
        }
    }

    /** 用系统默认应用打开聊天附件；FileProvider 给目标应用临时读权限。 */
    private fun openFile(path: String?): Boolean {
        if (path.isNullOrBlank()) return false
        val file = File(path)
        if (!file.exists()) return false
        val uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (e: Exception) {
            return false
        }
        val mime = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            startActivity(
                Intent.createChooser(view, "打开文件")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    override fun onDestroy() {
        try {
            multicastLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
        super.onDestroy()
    }
}
