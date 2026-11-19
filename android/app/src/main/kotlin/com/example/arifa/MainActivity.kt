package com.example.arifa

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.widget.Toast
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannelName = "arifa/native"
    private val eventChannelName = "arifa/events"
    private val captureRequestCode = 1001

    companion object {
        private var eventSink: EventChannel.EventSink? = null

        fun emit(type: String, text: String) {
            eventSink?.success(mapOf("type" to type, "text" to text))
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
            "captureScreen" -> requestScreenCapture(result)
            "openApp" -> result.success(openApp(call.argument<String>("target").orEmpty()))
            "dial" -> result.success(dialNumber(call.argument<String>("number").orEmpty(), false))
            "call" -> result.success(dialNumber(call.argument<String>("number").orEmpty(), true))
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
        startActivityForResult(manager.createScreenCaptureIntent(), captureRequestCode)
    }

    private var pendingCaptureResult: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != captureRequestCode) return
        val result = pendingCaptureResult
        pendingCaptureResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result?.error("DENIED", "Screen capture permission denied", null)
            return
        }
        val intent = Intent(this, ArifaService::class.java).apply {
            action = ArifaService.ACTION_CAPTURE
            putExtra("resultCode", resultCode)
            putExtra("data", data)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
        else startService(intent)
        result?.success("capturing")
    }

    private fun openApp(target: String): String {
        if (target.isBlank()) return "app name dao Emon Bhai"
        val pm = packageManager
        val direct = try {
            pm.getApplicationInfo(target.trim(), 0).packageName
        } catch (_: Exception) {
            null
        }
        val packageName = direct ?: resolveByLabel(target.trim())
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
            // Android blocks direct WiFi toggling for normal apps.
            startActivity(Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            ArifaAccessibilityService.instance?.tapWifiSwitch()
            return "settings opened - accessibility tap attempted"
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
}
