package com.pornshop.player.download

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.pornshop.player.MainActivity
import com.pornshop.player.data.DownloadCenter
import com.pornshop.player.data.DownloadStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** 把下载留在前台，锁屏或回到桌面后继续。 */
class DownloadKeeperService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var watch: Job? = null
    private var wake: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        DownloadCenter.install(applicationContext)
        ensureChannel()
        ServiceCompat.startForeground(
            this,
            NOTIF_ID,
            buildNotification("准备下载", "正在连接线路…"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pornshop:download").apply {
            setReferenceCounted(false)
            acquire(4 * 60 * 60 * 1000L)
        }
        watch = scope.launch {
            DownloadCenter.tasks.collectLatest { tasks ->
                val running = tasks.firstOrNull { it.status == DownloadStatus.RUNNING }
                val queued = tasks.count { it.status == DownloadStatus.QUEUED }
                if (running == null && queued == 0) return@collectLatest
                val title = running?.title ?: "下载队列"
                val text = when {
                    running != null && running.total > 0 ->
                        "正在下载 ${running.percent}% · 还排队 $queued 个"
                    running != null -> "正在解析播放列表…"
                    else -> "排队 $queued 个"
                }
                val manager = getSystemService(NotificationManager::class.java)
                manager.notify(NOTIF_ID, buildNotification(title, text))
            }
        }
        DownloadCenter.kick()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        DownloadCenter.kick()
        return START_STICKY
    }

    override fun onDestroy() {
        watch?.cancel()
        wake?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL, "离线下载", NotificationManager.IMPORTANCE_LOW)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .build()
    }

    private companion object {
        const val CHANNEL = "pornshop_downloads"
        const val NOTIF_ID = 18
    }
}
