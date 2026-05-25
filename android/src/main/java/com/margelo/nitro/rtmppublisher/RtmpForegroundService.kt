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
import android.util.Log
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
    val iconName = intent?.getStringExtra(EXTRA_ICON_NAME).orEmpty()
    ensureChannel()
    val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle(title)
      .setContentText(text)
      .setSmallIcon(resolveSmallIcon(iconName))
      .setOngoing(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .build()

    // startForeground can throw on Android 14+:
    //  - SecurityException if camera/mic runtime perms not granted at the
    //    moment of the FGS-start call (Android 14 checks at start time, not
    //    just at access time).
    //  - ForegroundServiceTypeException if the declared types don't match
    //    what's runtime-required.
    // We have to catch these — letting them propagate out of onStartCommand
    // crashes the service, which fires ForegroundServiceDidNotStartInTimeException
    // 5 seconds later and crashes the whole app.
    try {
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
    } catch (e: Exception) {
      Log.e(
        "RtmpForegroundService",
        "startForeground failed: ${e.javaClass.simpleName}: ${e.message} — " +
          "Android 14+ requires the relevant runtime permissions to be granted " +
          "before FGS-start. Stopping the service; stream will run without FGS " +
          "(OS may kill on background)."
      )
      running = false
      stopSelf()
    }
    return START_NOT_STICKY
  }

  override fun onDestroy() {
    running = false
    super.onDestroy()
  }

  // Resolve a drawable name against the host app's resources. The library
  // can't link the host's resource IDs at compile time, so we look it up
  // at runtime. Falls back to a system icon when empty or unresolvable.
  private fun resolveSmallIcon(name: String): Int {
    if (name.isEmpty()) return android.R.drawable.presence_video_online
    val resId = resources.getIdentifier(name, "drawable", packageName)
    if (resId == 0) {
      // Some hosts ship icons in mipmap (e.g. ic_launcher). Try that too.
      val mipmapId = resources.getIdentifier(name, "mipmap", packageName)
      if (mipmapId != 0) return mipmapId
      return android.R.drawable.presence_video_online
    }
    return resId
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
    const val EXTRA_ICON_NAME = "iconName"

    @Volatile var running: Boolean = false
      private set

    fun start(context: Context, title: String, text: String, iconName: String): Boolean {
      val intent = Intent(context, RtmpForegroundService::class.java).apply {
        putExtra(EXTRA_TITLE, title)
        putExtra(EXTRA_TEXT, text)
        putExtra(EXTRA_ICON_NAME, iconName)
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

    // Re-fire startService with new extras to update the live notification
    // (mid-stream prop change). Android delivers a fresh onStartCommand which
    // re-invokes startForeground with the new builder — no separate update API
    // exists in the SDK for "change the foreground notification".
    fun update(context: Context, title: String, text: String, iconName: String): Boolean {
      if (!running) return false
      return try {
        context.startService(
          Intent(context, RtmpForegroundService::class.java).apply {
            putExtra(EXTRA_TITLE, title)
            putExtra(EXTRA_TEXT, text)
            putExtra(EXTRA_ICON_NAME, iconName)
          }
        )
        true
      } catch (e: Exception) {
        false
      }
    }
  }
}
