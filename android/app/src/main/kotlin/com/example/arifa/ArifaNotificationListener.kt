package com.example.arifa

import android.app.Notification
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * Reads ONLY incoming WhatsApp message notifications, and only after the user
 * has turned Auto Reply ON and named at least one allowed contact.
 *
 * The message body is emitted to Dart (on-device) and never posted to a server
 * by this class. Non-allowed contacts, group summaries and empty messages are
 * dropped here so Dart never even sees them.
 */
class ArifaNotificationListener : NotificationListenerService() {

    companion object {
        const val PREFS = "arifa_wa_prefs"

        private val pending = ConcurrentHashMap<String, PendingIntent>()

        @Volatile
        var instance: ArifaNotificationListener? = null

        /** Opens the exact chat from the notification's own PendingIntent. */
        fun openChat(key: String): Boolean {
            val intent = pending[key] ?: return false
            return try {
                intent.send()
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private var prefs: SharedPreferences? = null

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        MainActivity.emitWhatsApp("status", "Notification access ON ♥")
    }

    override fun onListenerDisconnected() {
        MainActivity.emitWhatsApp("status", "Notification access OFF")
        super.onListenerDisconnected()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            requestRebind(ComponentName(this, ArifaNotificationListener::class.java))
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val notification = sbn ?: return
        val pkg = notification.packageName
        if (pkg != "com.whatsapp" && pkg != "com.whatsapp.w4b") return

        val p = prefs ?: return
        if (!p.getBoolean("auto_reply_enabled", false)) return

        val allowed = p.getString("allowed_contacts", "").orEmpty()
            .split(",")
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
        if (allowed.isEmpty()) return

        val n = notification.notification
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return

        val extras = n.extras
        val title = (extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
            ?: extras.getCharSequence(Notification.EXTRA_TITLE))
            ?.toString()?.trim().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString()?.trim().orEmpty()

        if (title.isEmpty() || text.isEmpty()) return
        val lowerText = text.lowercase()
        if (lowerText.contains("typing") || (lowerText.contains("...") && text.length < 8)) return

        val lowerTitle = title.lowercase()
        if (!allowed.any { it == "*" || lowerTitle.contains(it) || it.contains(lowerTitle) }) return

        n.contentIntent?.let { pending[notification.key] = it }

        val payload = JSONObject()
            .put("contact", title)
            .put("message", text)
            .put("key", notification.key)
            .put("package", pkg)
            .put("ts", System.currentTimeMillis())
        MainActivity.emitWhatsApp("whatsapp_message", payload.toString())
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn?.let { pending.remove(it.key) }
        super.onNotificationRemoved(sbn)
    }
}
