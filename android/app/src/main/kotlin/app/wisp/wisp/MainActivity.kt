package app.wisp.wisp

import android.Manifest
import android.app.PendingIntent
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageInstaller
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
import java.io.FileOutputStream

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

    private companion object {
        /** APK 的 MIME；ACTION_VIEW 靠它路由到系统安装器。 */
        const val APK_MIME = "application/vnd.android.package-archive"

        /** 安装暂存用的固定文件名（落在 cache/install/ 下）。 */
        const val STAGED_APK = "wisp-update.apk"

        /** 写进 PackageInstaller 会话里的条目名，随便取，不落文件系统。 */
        const val SESSION_APK = "wisp.apk"
    }

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
                    "installApk" -> installApkAsync(call.argument<String>("target"), result)
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
                // 里留下一个 0 字节或半截的 apk，用户点开就报
                // "packageInfo is null"。清完标记后不能只看开头 4 字节——
                // 截断包的头一样是 PK\x03\x04——必须比对实际长度。
                val size = contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
                if (size != src.length()) {
                    throw IllegalStateException("MediaStore size mismatch: $size != ${src.length()}")
                }
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
     * 拉起系统安装：'ok' / 'permission_required' / 'invalid_apk' / 'failed'。
     *
     * 2.2.3 改用 [PackageInstaller] 会话把 APK 字节**直接写进系统安装会话**，
     * 不再让安装器来读我们授权的 URI：
     * · 2.2.1 把 MediaStore 的 content:// 交出去，安装器读不到字节；
     * · 2.2.2 换成 FileProvider 了，可部分 ROM 的安装器会把 URI 转交给另一个
     *   进程（系统 PackageInstaller 服务），FLAG_GRANT_READ_URI_PERMISSION
     *   不跟着跨进程传递，那边读到的仍是空包，于是照样报
     *   "packageInfo is null"。
     * 会话模式下字节已经落在系统手里，不存在"读不到"这种失败。
     *
     * 写几十 MB 不能占着平台线程，所以整条流程丢后台线程，结果再回主线程。
     */
    private fun installApkAsync(target: String?, result: MethodChannel.Result) {
        if (target.isNullOrBlank()) {
            result.success("failed")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            openUnknownSourcesSettings()
            result.success("permission_required")
            return
        }
        Thread {
            val status = try {
                installApk(target)
            } catch (e: Exception) {
                "failed"
            }
            runOnUiThread { result.success(status) }
        }.start()
    }

    /**
     * 安装主流程（后台线程）：解析出可用 APK → 优先走系统安装会话，
     * 会话建不起来（个别 ROM 禁掉普通应用的 session）才退回 URI 方式。
     */
    private fun installApk(target: String): String {
        val apk = resolveInstallableApk(target) ?: return "invalid_apk"
        installViaSession(apk)?.let { return it }
        return installViaUri(apk)
    }

    /**
     * 把 APK 字节写进 [PackageInstaller] 会话并提交。
     *
     * 返回 null 表示这台机器上建不了会话，交给调用方退回 URI 方式。
     */
    private fun installViaSession(apk: File): String? {
        var sessionId = -1
        return try {
            val installer = packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            ).apply {
                setAppPackageName(packageName)
            }
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                session.openWrite(SESSION_APK, 0, apk.length()).use { out ->
                    apk.inputStream().use { input -> input.copyTo(out) }
                    session.fsync(out)
                }
                session.commit(installResultSender(sessionId))
            }
            "ok"
        } catch (e: Exception) {
            try {
                if (sessionId >= 0) packageManager.packageInstaller.abandonSession(sessionId)
            } catch (_: Exception) {
            }
            null
        }
    }

    /** 会话结果回调用的 PendingIntent（Android 12+ 必须显式声明可变性）。 */
    private fun installResultSender(sessionId: Int): IntentSender {
        val intent = Intent(this, InstallResultReceiver::class.java)
            .putExtra(InstallResultReceiver.EXTRA_SESSION_ID, sessionId)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        return PendingIntent.getBroadcast(this, sessionId, intent, flags).intentSender
    }

    /** 兜底：把本地文件经 FileProvider 授权给安装器自己读。 */
    private fun installViaUri(apk: File): String {
        val uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        } catch (e: Exception) {
            return "invalid_apk"
        }
        if (!uriReadsWholeFile(uri, apk.length())) return "invalid_apk"
        return startInstaller(uri)
    }

    /** 代开「安装未知应用」授权页；拿不到系统页也不阻断，返回值已说明。 */
    private fun openUnknownSourcesSettings() {
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (_: Exception) {
        }
    }

    /**
     * 交 URI 给安装器。优先 ACTION_VIEW + APK MIME（现代安装器都认），
     * 少数 ROM 只注册了旧的 ACTION_INSTALL_PACKAGE 再退一步。
     */
    private fun startInstaller(uri: Uri): String {
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME)
            // 部分 ROM 只从 ClipData 继承 URI 授权，不认 Intent 上的 flag。
            clipData = ClipData.newUri(contentResolver, STAGED_APK, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val handler = try {
            packageManager.resolveActivity(view, PackageManager.MATCH_DEFAULT_ONLY)
        } catch (e: Exception) {
            null
        }
        if (handler != null) {
            // 跨进程时 grant 可能被 ROM 吞掉，对解析到的安装器显式再授一次。
            val handlerPkg = handler.activityInfo?.packageName
            if (!handlerPkg.isNullOrBlank()) {
                try {
                    grantUriPermission(
                        handlerPkg,
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: Exception) {
                }
            }
            try {
                startActivity(view)
                return "ok"
            } catch (_: Exception) {
            }
        }
        val legacy = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            data = uri
            clipData = ClipData.newUri(contentResolver, STAGED_APK, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            startActivity(legacy)
            "ok"
        } catch (e: Exception) {
            "failed"
        }
    }

    /** 授权出去的 URI 必须能读出和文件一模一样的长度，短了就是空包/半截包。 */
    private fun uriReadsWholeFile(uri: Uri, expected: Long): Boolean {
        if (expected <= 0L) return false
        return try {
            contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize == expected } ?: false
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 把安装句柄统一落成一份**本应用亲手写过、亲手校验过**的本地 APK。
     *
     * 候选顺序：上游给的本地路径 → 下载时发布用的源副本 → 系统下载目录
     * 回读 → 上一次的安装暂存。逐个用 [parsesAsWispApk] 验，第一个通过的
     * 复制进 cache/install 并 fsync 后交出去；一个都验不过就返回 null，
     * 由调用方给出「重新下载」——绝不让安装器去撞解析失败。
     */
    private fun resolveInstallableApk(target: String): File? {
        val candidates = ArrayList<File>()
        if (!target.startsWith("content://")) candidates.add(File(target))
        lastPublishedPath?.let { candidates.add(File(it)) }
        if (target.startsWith("content://")) stageContentUri(target)?.let { candidates.add(it) }
        candidates.add(File(installStagingDir(), STAGED_APK))

        for (candidate in candidates) {
            if (!parsesAsWispApk(candidate)) continue
            return stageForInstall(candidate) ?: candidate
        }
        return null
    }

    /**
     * 用系统自己的 PackageManager 解析一遍，解析不出来就是坏包。
     *
     * 这一步是整个修复的关键：AOSP 的 PackageInstallerActivity 内部也调
     * PackageUtil.getPackageInfo，返回 null 时用户只会看到一句
     * "packageInfo is null"，没有任何可照做的信息。在这里先解析，
     * 失败就换成中文提示"重新下载"。
     */
    private fun parsesAsWispApk(file: File): Boolean {
        if (!file.isFile || file.length() <= 0L) return false
        return try {
            val head = ByteArray(4)
            val read = file.inputStream().use { it.read(head) }
            if (read < 4 || head[0] != 0x50.toByte() || head[1] != 0x4B.toByte()) return false
            // 只认本应用自己的包：拿别的 apk 来装等于覆盖用户装的东西。
            packageManager.getPackageArchiveInfo(file.absolutePath, 0)?.packageName == packageName
        } catch (e: Exception) {
            false
        }
    }

    /** 复制进 cache/install 并 fsync：交出去的文件必须已经完整落盘。 */
    private fun stageForInstall(src: File): File? {
        val dest = File(installStagingDir(), STAGED_APK)
        return try {
            if (src.canonicalPath == dest.canonicalPath) {
                return if (dest.length() > 0L) dest else null
            }
            FileOutputStream(dest).use { out ->
                src.inputStream().use { input -> input.copyTo(out) }
                out.flush()
                out.fd.sync()
            }
            if (dest.length() > 0L && dest.length() == src.length()) dest else null
        } catch (e: Exception) {
            null
        }
    }

    private fun installStagingDir(): File = File(cacheDir, "install").apply { mkdirs() }

    /** 把系统下载目录里的 content:// 复制回应用 cache（cache-path 已授权）。 */
    private fun stageContentUri(target: String): File? {
        val staged = File(installStagingDir(), STAGED_APK)
        // 先删掉上一次的暂存：写失败时不能把旧包当成这一次的结果。
        try {
            staged.delete()
        } catch (_: Exception) {
        }
        return try {
            val written = contentResolver.openInputStream(Uri.parse(target))?.use { input ->
                var total = 0L
                FileOutputStream(staged).use { sink ->
                    total = input.copyTo(sink)
                    sink.flush()
                    sink.fd.sync()
                }
                total
            } ?: 0L
            if (written > 0L && staged.length() == written) staged else null
        } catch (e: Exception) {
            null
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
