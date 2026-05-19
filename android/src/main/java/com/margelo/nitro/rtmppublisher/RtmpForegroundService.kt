package com.margelo.nitro.rtmppublisher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

private const val CHANNEL_ID = "rtmp_publisher_channel"
private const val NOTIFICATION_ID = 0xABCD

/**
 * Foreground service hosting the streaming session so Android won't kill the
 * process when the activity backgrounds. The notification keeps the OS happy;
 * the encoder + RTMP TX run in this same process, just not in this class.
 */
class RtmpForegroundService : Service() {

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Streaming"
    val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Live stream in progress"
    ensureChannel()
    val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle(title)
      .setContentText(text)
      .setSmallIcon(android.R.drawable.presence_video_online)
      .setOngoing(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .build()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      // Android 14+ requires explicit foregroundServiceType.
      startForeground(
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
          ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
      )
    } else {
      startForeground(NOTIFICATION_ID, notification)
    }
    running = true
    return START_NOT_STICKY
  }

  override fun onDestroy() {
    running = false
    super.onDestroy()
  }

  private fun ensureChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val mgr = getSystemService(NotificationManager::class.java) ?: return
    if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
    mgr.createNotificationChannel(
      NotificationChannel(
        CHANNEL_ID,
        "RTMP Streaming",
        NotificationManager.IMPORTANCE_LOW
      ).apply { description = "Persistent notification while streaming" }
    )
  }

  companion object {
    const val EXTRA_TITLE = "title"
    const val EXTRA_TEXT = "text"

    @Volatile var running: Boolean = false
      private set

    fun start(context: Context, title: String, text: String): Boolean {
      val intent = Intent(context, RtmpForegroundService::class.java).apply {
        putExtra(EXTRA_TITLE, title)
        putExtra(EXTRA_TEXT, text)
      }
      return try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          context.startForegroundService(intent)
        } else {
          context.startService(intent)
        }
        true
      } catch (e: Exception) {
        false
      }
    }

    fun stop(context: Context) {
      context.stopService(Intent(context, RtmpForegroundService::class.java))
    }
  }
}
