package com.arifa.app.arifa

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.telephony.SmsManager
import android.util.Log
import android.widget.Toast
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val methodChannelName = "arifa/native"
    private val eventChannelName = "arifa/events"
    private val whatsappEventChannelName = "arifa/whatsapp_events"
    private val captureRequestCode = 1001

    companion object {
        private var eventSink: EventChannel.EventSink? = null
        private var waEventSink: EventChannel.EventSink? = null
        private val mainHandler = Handler(Looper.getMainLooper())
        private var pendingCaptureResult: MethodChannel.Result? = null

        fun emit(type: String, text: String) {
            eventSink?.success(mapOf("type" to type, "text" to text))
        }

        fun emitWhatsApp(type: String, payload: String) {
            waEventSink?.success(mapOf("type" to type, "payload" to payload))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result -> handleMethod(call, result) }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, whatsappEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    waEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    waEventSink = null
                }
            })
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startWakeService" -> {
                val ok = startForegroundServiceSafely(null)
                result.success(ok)
            }
            "stopWakeService" -> {
                stopService(Intent(this, ArifaService::class.java))
                result.success(true)
            }
            "isServiceRunning" -> result.success(ArifaService.isRunning)
            "setWakeEnabled" -> result.success(
                setWakeEnabled(call.argument<Boolean>("enabled") ?: true)
            )
            "captureScreen" -> requestScreenCapture(result)
            "clearScreenCapture" -> result.success(clearScreenCapture())
            "openApp" -> result.success(openApp(call.argument<String>("target").orEmpty()))
            "dial" -> result.success(dialNumber(call.argument<String>("number").orEmpty(), false))
            "call" -> result.success(dialNumber(call.argument<String>("number").orEmpty(), true))
            "sendSms" -> result.success(
                sendSms(
                    call.argument<String>("phone").orEmpty(),
                    call.argument<String>("body").orEmpty(),
                )
            )
            "sendWhatsApp" -> result.success(
                sendWhatsApp(
                    call.argument<String>("contact").orEmpty(),
                    call.argument<String>("message").orEmpty(),
                )
            )
            "toggleWifi" -> result.success(toggleWifi(call.argument<Boolean>("enable")))
            "playSong" -> result.success(playSong(call.argument<String>("query").orEmpty()))
            "openTtsSettings" -> result.success(openTtsSettings())
            "openAccessibilitySettings" -> result.success(openAccessibilitySettings())
            "clickSendButton" -> result.success(
                if (ArifaAccessibilityService.instance?.clickSendButton() == true) "clicked" else "not found"
            )
            "configureWhatsAppAutoReply" -> result.success(configureWhatsApp(call))
            "isNotificationAccessEnabled" -> result.success(notificationAccessEnabled())
            "isAccessibilityEnabled" -> result.success(accessibilityEnabled())
            "openNotificationAccessSettings" -> result.success(openNotificationAccessSettings())
            "openWhatsAppChat" -> result.success(
                ArifaNotificationListener.openChat(call.argument<String>("key").orEmpty())
            )
            "openWhatsApp" -> result.success(openApp("com.whatsapp"))
            "typeWhatsAppReply" -> result.success(
                if (ArifaAccessibilityService.instance?.typeAndSend(
                        call.argument<String>("text").orEmpty(),
                    ) == true
                ) {
                    "sent"
                } else {
                    "not found"
                }
            )
            else -> result.notImplemented()
        }
    }

    private fun startForegroundServiceSafely(action: String?): Boolean {
        val intent = Intent(this, ArifaService::class.java)
        if (action != null) intent.action = action
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            true
        } catch (e: Exception) {
            emit("service", ".service start fail: ${e.message}")
            false
        }
    }

    private fun requestScreenCapture(result: MethodChannel.Result) {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingCaptureResult = result

        // ArifaService writes the JPEG on its own handler thread. It reports the
        // real path through this callback; the MethodChannel.Result is completed
        // on the main thread because the Flutter engine requires it.
        ArifaService.onCaptureDone = { path ->
            mainHandler.post {
                val pending = pendingCaptureResult
                pendingCaptureResult = null
                if (pending == null) return@post // activity/engine already went away
                try {
                    if (path.isNullOrEmpty()) {
                        pending.error(
                            "CAPTURE_FAILED",
                            "স্ক্রিনশট বাঁচাতে পারলাম না Emon Bhai",
                            null,
                        )
                    } else {
                        pending.success(path)
                    }
                } catch (e: Exception) {
                    Log.w("MainActivity", "Capture result already gone: ${e.message}")
                }
            }
        }
        try {
            startActivityForResult(manager.createScreenCaptureIntent(), captureRequestCode)
        } catch (e: Exception) {
            ArifaService.onCaptureDone = null
            val pending = pendingCaptureResult
            pendingCaptureResult = null
            pending?.error("CAPTURE_ERROR", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != captureRequestCode) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            ArifaService.onCaptureDone = null
            val result = pendingCaptureResult
            pendingCaptureResult = null
            result?.error("DENIED", "Screen capture permission denied", null)
            return
        }
        val intent = Intent(this, ArifaService::class.java).apply {
            action = ArifaService.ACTION_CAPTURE
            putExtra("resultCode", resultCode)
            putExtra("data", data)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
            else startService(intent)
        } catch (e: Exception) {
            ArifaService.onCaptureDone = null
            val result = pendingCaptureResult
            pendingCaptureResult = null
            result?.error("CAPTURE_ERROR", e.message, null)
        }
        // Do NOT complete the result here: ArifaService calls onCaptureDone with
        // the actual saved path once the screenshot has been written.
    }

    private fun clearScreenCapture(): Boolean {
        return try {
            val file = File(cacheDir, ArifaService.SCREEN_CAPTURE_FILE)
            if (file.exists()) file.delete() else true
        } catch (_: Exception) {
            false
        }
    }

    private fun openApp(target: String): String {
        if (target.isBlank()) return "app name dao Emon Bhai"
        val pm = packageManager
        val label = target.trim()
        // Prefer launcher-activity resolution: it is covered by the narrow
        // <queries> launcher intent filter on Android 11+.
        var packageName = resolveByLabel(label)
        if (packageName == null) {
            // Exact package names work only when covered by <queries>
            // (e.g. com.whatsapp / com.whatsapp.w4b). Try the launch intent
            // directly, then the application info as a last resort.
            packageName = try {
                pm.getLaunchIntentForPackage(label)?.component?.packageName
                    ?: pm.getApplicationInfo(label, 0).packageName
            } catch (_: Exception) {
                null
            }
        }
        if (packageName == null) {
            Toast.makeText(this, "$target পাওয়া যায়নি", Toast.LENGTH_SHORT).show()
            return "$target install করা আছে কি?"
        }
        val launch = pm.getLaunchIntentForPackage(packageName)
            ?: return "$target open করা যায়নি"
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(launch)
        return "opened $packageName"
    }

    private fun resolveByLabel(label: String): String? {
        val pm = packageManager
        val intents = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
        return intents.firstOrNull { info ->
            info.loadLabel(pm).toString().contains(label, ignoreCase = true)
        }?.activityInfo?.packageName
    }

    private fun dialNumber(number: String, call: Boolean): String {
        if (number.isBlank()) return "number dao Emon Bhai"
        val uri = Uri.parse("tel:${number.replace(Regex("[\\s-]"), "")}")
        val action = if (call) Intent.ACTION_CALL else Intent.ACTION_DIAL
        val intent = Intent(action, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (call && ContextCompat.checkSelfPermission(this, Manifest.permission.CALL_PHONE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            // Dialer is the safe fallback; user presses the green button.
            intent.action = Intent.ACTION_DIAL
        }
        return try {
            startActivity(intent)
            if (intent.action == Intent.ACTION_CALL) "calling" else "dialer opened"
        } catch (e: Exception) {
            "call fail: ${e.message}"
        }
    }

    private fun sendSms(phone: String, body: String): String {
        if (phone.isBlank() || body.isBlank()) return "number o message dao Emon Bhai"
        val to = phone.replace(Regex("[\\s-]"), "")
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$to")).apply {
                    putExtra("sms_body", body)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
                "SMS app khullo — pathano chai"
            } else {
                @Suppress("DEPRECATION")
                val manager = SmsManager.getDefault()
                val parts = manager.divideMessage(body)
                if (parts.size == 1) {
                    manager.sendTextMessage(to, null, body, null, null)
                } else {
                    manager.sendMultipartTextMessage(to, null, ArrayList(parts), null, null)
                }
                "SMS pathano holo"
            }
        } catch (e: Exception) {
            "SMS fail: ${e.message}"
        }
    }

    private fun sendWhatsApp(contact: String, message: String): String {
        val encoded = Uri.encode(message)
        val intent = if (contact.matches(Regex("^\\+?[0-9][0-9\\s-]{5,}$"))) {
            Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/${contact.replace(Regex("[^0-9]"), "")}?text=$encoded"))
        } else {
            Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, message)
                setPackage("com.whatsapp")
            }
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            ArifaAccessibilityService.instance?.clickSendButton()
            "whatsapp opened"
        } catch (e: Exception) {
            "whatsapp fail (installed?): ${e.message}"
        }
    }

    private fun toggleWifi(enable: Boolean?): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android blocks direct WiFi toggling for normal apps. Give the
            // Settings screen time to load before the accessibility tap.
            startActivity(Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            Handler(Looper.getMainLooper()).postDelayed({
                ArifaAccessibilityService.instance?.tapWifiSwitch()
            }, 650)
            return "settings opened - accessibility tap scheduled"
        }
        @Suppress("DEPRECATION")
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
        @Suppress("DEPRECATION")
        wifiManager.isWifiEnabled = enable ?: !wifiManager.isWifiEnabled
        return "wifi toggled"
    }

    private fun playSong(query: String): String {
        val q = if (query.isBlank()) "Bangla hits" else query
        val url = "https://www.youtube.com/results?search_query=${Uri.encode(q)}"
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            "song search opened"
        } catch (e: Exception) {
            "song fail: ${e.message}"
        }
    }

    private fun openTtsSettings(): String {
        return try {
            startActivity(Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            "tts data settings"
        } catch (e: Exception) {
            try {
                startActivity(Intent("com.android.settings.TTS_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                "tts settings"
            } catch (e2: Exception) {
                "tts settings fail"
            }
        }
    }

    private fun openAccessibilitySettings(): String {
        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return "accessibility settings"
    }

    // ---------- Wake / boot ----------

    private fun setWakeEnabled(enabled: Boolean): Boolean {
        val prefs = getSharedPreferences(ArifaNotificationListener.PREFS, Context.MODE_PRIVATE)
        prefs.edit().putBoolean("wake_enabled", enabled).apply()
        return true
    }

    // ---------- WhatsApp Auto Reply ----------

    private fun configureWhatsApp(call: MethodCall): Boolean {
        val enabled = call.argument<Boolean>("enabled") ?: false
        val allow = call.argument<List<String>>("allowList") ?: emptyList()
        val important = call.argument<List<String>>("importantContacts") ?: emptyList()
        val prefs = getSharedPreferences(ArifaNotificationListener.PREFS, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean("auto_reply_enabled", enabled)
            .putString("allowed_contacts", allow.joinToString(","))
            .putString("important_contacts", important.joinToString(","))
            .apply()
        return true
    }

    private fun notificationAccessEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners").orEmpty()
        return flat.split(":").any { entry ->
            ComponentName.unflattenFromString(entry)?.packageName == packageName
        }
    }

    private fun accessibilityEnabled(): Boolean {
        if (Settings.Secure.getString(contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED) != "1") {
            return false
        }
        val expected = ComponentName(this, ArifaAccessibilityService::class.java).flattenToString()
        return Settings.Secure
            .getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            .orEmpty()
            .split(":")
            .any { it.equals(expected, ignoreCase = true) }
    }

    private fun openNotificationAccessSettings(): Boolean {
        return try {
            startActivity(
                Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    override fun onDestroy() {
        ArifaService.onCaptureDone = null
        pendingCaptureResult = null
        super.onDestroy()
    }
}
