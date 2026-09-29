package app.passvault

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Clears copied secrets on schedule. Android freezes background apps within seconds, so an in-app timer
 * never fires once the user switches away to paste; a foreground service keeps the timer alive and is
 * told when the app is swiped away from recents. It runs only while a copied value is pending.
 */
class ClipboardClearService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val expire = Runnable { clearAndStop() }
    private var clearOnExit = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CLEAR) { clearAndStop(); return START_NOT_STICKY }
        val delay = intent?.getLongExtra(EXTRA_DELAY, 60_000L) ?: 60_000L
        clearOnExit = intent?.getBooleanExtra(EXTRA_CLEAR_ON_EXIT, true) ?: true
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(delay), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        handler.removeCallbacks(expire); handler.postDelayed(expire, delay)
        return START_NOT_STICKY
    }

    // Swiping the app away from recents counts as closing (locking) the vault.
    override fun onTaskRemoved(rootIntent: Intent?) { if (clearOnExit) clearAndStop() }

    override fun onDestroy() { handler.removeCallbacks(expire); super.onDestroy() }

    private fun clearAndStop() {
        // A background service cannot read the clipboard to check the clip is still ours, so it clears it.
        wipe(this)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE); stopSelf()
    }

    private fun notification(delay: Long): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.seed_notif_channel), NotificationManager.IMPORTANCE_LOW).apply { description = getString(R.string.seed_notif_channel_desc); setShowBadge(false) })
        val clearNow = PendingIntent.getService(this, 1, Intent(this, ClipboardClearService::class.java).setAction(ACTION_CLEAR), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_clipboard_clear).setContentTitle(getString(R.string.seed_notif_title))
            .setContentText(getString(R.string.seed_notif_text)).setContentIntent(open)
            .setWhen(System.currentTimeMillis() + delay).setUsesChronometer(true).setChronometerCountDown(true).setShowWhen(true)
            .setOngoing(true).setVisibility(Notification.VISIBILITY_PUBLIC).setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, getString(R.string.seed_notif_clear), clearNow).build())
            .build()
    }

    companion object {
        private const val CHANNEL = "clipboard"; private const val NOTIFICATION_ID = 7
        private const val ACTION_CLEAR = "app.passvault.CLEAR_CLIPBOARD"
        private const val EXTRA_DELAY = "delay"; private const val EXTRA_CLEAR_ON_EXIT = "clearOnExit"
        fun schedule(context: Context, delayMillis: Long, clearOnExit: Boolean) = ContextCompat.startForegroundService(context,
            Intent(context, ClipboardClearService::class.java).putExtra(EXTRA_DELAY, delayMillis).putExtra(EXTRA_CLEAR_ON_EXIT, clearOnExit))
        /** Overwrites the clip with an empty value first (keyboard clipboard histories keep the last item), then clears it. */
        fun wipe(context: Context) {
            val clipboard = context.getSystemService(ClipboardManager::class.java)
            runCatching { clipboard.setPrimaryClip(android.content.ClipData.newPlainText("", "")) }
            runCatching { clipboard.clearPrimaryClip() }
            android.util.Log.i("PassVault", "Clipboard cleared")
        }
        fun cancel(context: Context) { context.stopService(Intent(context, ClipboardClearService::class.java)) }
    }
}
