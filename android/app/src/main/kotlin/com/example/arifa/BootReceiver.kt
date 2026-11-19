package com.example.arifa

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.LOCKED_BOOT_COMPLETED"
        ) return

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
        // arrived while the app was down (wa_pending_messages in secure storage).
        try {
            val app = context.packageManager.getLaunchIntentForPackage(context.packageName)
            app?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            app?.let { context.startActivity(it) }
        } catch (e: Exception) {
            // Some OEM launchers block background activity starts.
        }
    }
}
