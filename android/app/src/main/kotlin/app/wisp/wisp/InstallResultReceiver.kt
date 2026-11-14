package app.wisp.wisp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log

/**
 * [PackageInstaller] 会话的结果回调。
 *
 * 只用来打日志：用户能看到的安装页由系统自己弹出，装没装成界面上一目了然。
 * 留着它是因为 `session.commit()` 必须给一个 IntentSender，而这个
 * receiver 能在出问题时给出 `EXTRA_STATUS_MESSAGE`（比如签名冲突、
 * 版本降级被拒），排查时比"用户说装不上"有用得多。
 *
 * `exported=false`：只有我们自己发起、由系统代投的 PendingIntent 能触达。
 */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE
        )
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        Log.i(TAG, "install session status=$status message=$message")
    }

    companion object {
        private const val TAG = "WispInstall"

        /** 会话 id，仅用于日志里把结果和某次安装对上。 */
        const val EXTRA_SESSION_ID = "wisp.install.sessionId"
    }
}
