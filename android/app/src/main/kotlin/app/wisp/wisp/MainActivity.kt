package app.wisp.wisp

import android.Manifest
import android.content.ClipData
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

    /** 最近一次成功发布到系统下载目录时用的源副本；安装时的兜底路径。 */
    private var lastPublishedPath: String? = null

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
     * Android 10+ 用 MediaStore.Downloads，Android 9 及以下直接写公共目录
     * （权限限定 maxSdk=28）。发布后会做完整性自检，坏包不留给用户。
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
                // copyTo 返回实际写入字节数，写完先和源文件对一次账。
                val written = contentResolver.openOutputStream(uri)?.use { sink ->
                    src.inputStream().use { input -> input.copyTo(sink) }
                } ?: 0L
                if (written <= 0L || written != src.length()) {
                    throw IllegalStateException("MediaStore write incomplete")
                }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                // 部分 ROM 在 IS_PENDING 1→0 时会把内容丢掉，系统下载目录
                // 里留下一个 0 字节 apk，用户点开就报 "packageInfo is null"。
                // 清完标记再读开头 4 字节确认还是合法 ZIP，不合法就撤回发布。
                val head = ByteArray(4)
                val read = contentResolver.openInputStream(uri)?.use { it.read(head) } ?: -1
                if (read < 4 || head[0] != 0x50.toByte() || head[1] != 0x4B.toByte()) {
                    throw IllegalStateException("MediaStore content is not a valid APK")
                }
                rememberPublished(src, uri.toString())
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
            return rememberPublished(src, copyToAppDownloads(src))
        }
        return rememberPublished(src, copyToPublicDownloads(src) ?: copyToAppDownloads(src))
    }

    /** 发布成功后记下源副本，安装时作为 content:// 读不到时的兜底。 */
    private fun rememberPublished(src: File, published: String?): String? {
        if (published != null) lastPublishedPath = src.absolutePath
        return published
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

    /**
     * 拉起系统安装界面：'ok' / 'permission_required' / 'invalid_apk' / 'failed'。
     *
     * 交给安装器的必须是**本应用自己能授权的 URI**。MediaStore 的 content://
     * 归系统 MediaProvider，本应用发出的 FLAG_GRANT_READ_URI_PERMISSION 对它
     * 不生效；安装器 StagingAsyncTask 复制出空包时就会报 "packageInfo is null"
     * （AOSP 里 PackageUtil.getPackageInfo 返回 null）。所以这里统一转成
     * FileProvider 授权的本地文件，并在启动前校验 ZIP 魔数。
     */
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
        val apk = resolveInstallableApk(target) ?: return "invalid_apk"
        val uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        } catch (e: Exception) {
            return "failed"
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            // 部分 ROM 只从 ClipData 继承 URI 授权，不认 Intent 上的 flag。
            clipData = ClipData.newUri(contentResolver, "wisp-update.apk", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
        }
        // 双保险：对解析到的安装器显式授权，避免跨进程时 grant 丢失。
        try {
            val handler = packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
            if (!handler.isNullOrBlank()) {
                grantUriPermission(handler, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } catch (_: Exception) {
        }
        return try {
            startActivity(intent)
            "ok"
        } catch (e: Exception) {
            "failed"
        }
    }

    /** 把安装句柄统一落成本应用可读、可被 FileProvider 授权的本地 APK。 */
    private fun resolveInstallableApk(target: String): File? {
        if (target.startsWith("content://")) {
            // 只有本次发布成功才拿得到 content://；这时 lastPublishedPath
            // 是同一份、下载时已校验过 sha256 的源副本，比 MediaStore 回读
            // 更可信（部分 ROM 回读会拿到半截包）。优先用它，也省掉一遍
            // 几十 MB 的复制。
            lastPublishedPath?.let { path ->
                val src = File(path)
                if (isUsableApk(src)) return src
            }
            return stageContentUri(target)?.takeIf { isUsableApk(it) }
        }
        val direct = File(target)
        if (isUsableApk(direct)) return direct
        return lastPublishedPath?.let { File(it) }?.takeIf { isUsableApk(it) }
    }

    /** 把系统下载目录里的 content:// 复制回应用 cache（cache-path 已授权）。 */
    private fun stageContentUri(target: String): File? {
        val staged = File(File(cacheDir, "install").apply { mkdirs() }, "wisp-update.apk")
        return try {
            val written = contentResolver.openInputStream(Uri.parse(target))?.use { input ->
                staged.outputStream().use { sink -> input.copyTo(sink) }
            } ?: 0L
            if (written > 0L) staged else null
        } catch (e: Exception) {
            null
        }
    }

    /** 空文件 / 半截包在这里就拦住，别把烂包丢给系统安装器。 */
    private fun isUsableApk(file: File): Boolean {
        if (!file.exists() || file.length() <= 0L) return false
        return try {
            val head = ByteArray(4)
            val read = file.inputStream().use { it.read(head) }
            read >= 4 && head[0] == 0x50.toByte() && head[1] == 0x4B.toByte()
        } catch (e: Exception) {
            false
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
