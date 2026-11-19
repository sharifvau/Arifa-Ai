package com.arifa.app.arifa

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // LOCKED_BOOT_COMPLETED was removed: the receiver is not direct-boot
        // aware and MODE_PRIVATE prefs are unavailable before unlock (M29).
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        // Only restart the listener when the user left wake word enabled.
        val prefs = context.getSharedPreferences(
            ArifaNotificationListener.PREFS,
            Context.MODE_PRIVATE,
        )
        if (!prefs.getBoolean("wake_enabled", true)) return

        // Android 13+ requires the notification permission for a visible FGS.
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) return

        try {
            val service = Intent(context, ArifaService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(service)
            } else {
                context.startService(service)
            }
        } catch (e: Exception) {
            // Android 12+ rejects background FGS starts unless an exemption
            // applies. The user can start ARIFA by opening the app instead.
        }

        // A fresh Flutter isolate is required to drain WhatsApp messages that
        // arrived while the app was down. Background Activity starts are blocked
        // on modern/OEM Android, so show a tappable notification instead (M29).
        val app = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return
        app.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val pendingIntent = PendingIntent.getActivity(context, 0, app, flags)
        val channelId = "arifa_boot"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "ARIFA",
                NotificationManager.IMPORTANCE_LOW,
            )
            context.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("ARIFA")
            .setContentText("Tap to drain pending messages Emon Bhai")
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(1002, notification)
        } catch (_: Exception) {
            // Notification permission may be missing; the user can open ARIFA.
        }
    }
}
