package com.arifa.app.arifa

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.media.ImageReader
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer

/**
 * Foreground service that:
 * 1) keeps ARIFA alive in the background,
 * 2) runs continuous SpeechRecognizer and fires on the wake word "Arifa",
 * 3) performs MediaProjection screenshots when asked.
 */
class ArifaService : Service() {

    companion object {
        const val ACTION_CAPTURE = "com.arifa.app.arifa.CAPTURE"
        const val CHANNEL_ID = "arifa_foreground"
        const val NOTIFICATION_ID = 1002
        const val SCREEN_CAPTURE_FILE = "arifa_screen.jpg"
        private const val MAX_CAPTURE_DIMENSION = 1280
        private const val JPEG_QUALITY = 80

        @Volatile
        var isRunning = false

        /** Registered by MainActivity while a capture request is in flight. */
        @Volatile
        var onCaptureDone: ((String?) -> Unit)? = null
    }

    /**
     * Single exit point for a capture: UI still gets the event channel update,
     * while MainActivity completes its pending MethodChannel.Result with the
     * actual file path (posted to the main thread there).
     */
    private fun finishCapture(path: String?) {
        MainActivity.emit("screen", path ?: "স্ক্রিনশট ব্যর্থ Emon Bhai")
        val callback = onCaptureDone
        onCaptureDone = null
        callback?.invoke(path)
    }

    private var recognizer: SpeechRecognizer? = null
    private var handler: Handler? = null
    private var thread: HandlerThread? = null
    private val wakeWords = listOf("arifa", "আরিফা", "আরিফা ", "arifa,")

    override fun onCreate() {
        super.onCreate()
        createChannel()
        thread = HandlerThread("ArifaWakeThread").also { it.start() }
        handler = Handler(thread!!.looper)
        isRunning = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CAPTURE) {
            startFg(ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION, "স্ক্রিন ধরছি Emon Bhai...")
            captureScreen(intent)
        } else {
            startFg(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, "Emon Bhai-র জন্য শুনছি ♥")
            startWakeListening()
        }
        return START_STICKY
    }

    private fun startFg(type: Int, text: String) {
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "ARIFA Background",
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "Always listening for Emon Bhai" }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("ARIFA")
            .setContentText(text)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun startWakeListening() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            MainActivity.emit("permission", "RECORD_AUDIO permission নেই Emon Bhai")
            return
        }
        if (recognizer == null) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(this)
            recognizer?.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}

                override fun onError(error: Int) {
                    MainActivity.emit("wake_error", "SpeechRecognizer error: $error")
                    scheduleRestart()
                }

                override fun onResults(results: Bundle?) {
                    val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val heard = list?.firstOrNull().orEmpty()
                    if (heard.isNotBlank() && containsWake(heard)) {
                        MainActivity.emit("wake", heard)
                        launchAppOnWake()
                    }
                    scheduleRestart()
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val heard = list?.firstOrNull().orEmpty()
                    if (heard.isNotBlank() && containsWake(heard)) {
                        MainActivity.emit("wake", heard)
                        launchAppOnWake()
                        recognizer?.stopListening()
                    }
                }

                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "bn-BD")
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 2)
        }
        try {
            recognizer?.startListening(intent)
        } catch (e: Exception) {
            Log.e("ArifaService", "startListening failed", e)
            scheduleRestart()
        }
    }

    private fun containsWake(text: String): Boolean {
        val lower = text.lowercase()
        return wakeWords.any { lower.contains(it.lowercase()) }
    }

    /**
     * Bring ARIFA to the front when the wake word is heard in the background,
     * so the Dart isolate is alive to answer and to drain pending WhatsApp
     * replies. OEMs may block background activity starts — ignore failures.
     */
    private fun launchAppOnWake() {
        val app = packageManager.getLaunchIntentForPackage(packageName) ?: return
        app.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        try {
            startActivity(app)
        } catch (_: Exception) {
        }
    }

    private fun scheduleRestart() {
        handler?.postDelayed({
            if (isRunning) {
                try {
                    startWakeListening()
                } catch (_: Exception) {
                    scheduleRestart()
                }
            }
        }, 900)
    }

    private fun captureScreen(intent: Intent) {
        val resultCode = intent.getIntExtra("resultCode", 0)
        @Suppress("DEPRECATION")
        val data = intent.getParcelableExtra("data") as? Intent
        if (data == null || resultCode == 0) {
            finishCapture(null)
            return
        }
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = try {
            manager.getMediaProjection(resultCode, data)
        } catch (e: Exception) {
            finishCapture(null)
            return
        }

        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi
        val reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        val display = projection.createVirtualDisplay(
            "ArifaScreen", width, height, density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader.surface, null, handler,
        )

        reader.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val plane = image.planes[0]
                val buffer: ByteBuffer = plane.buffer
                val pixelStride = plane.pixelStride
                val rowStride = plane.rowStride
                val rowPadding = rowStride - pixelStride * width
                val bitmap = Bitmap.createBitmap(
                    width + rowPadding / pixelStride,
                    height,
                    Bitmap.Config.ARGB_8888,
                )
                bitmap.copyPixelsFromBuffer(buffer)
                val cropped = Bitmap.createBitmap(bitmap, 0, 0, width, height)

                // Downscale natively before saving so Gemini inline_data stays
                // comfortably below its ~4MB limit: max edge 1280px, quality 80.
                val longest = maxOf(cropped.width, cropped.height)
                val scale = minOf(1f, MAX_CAPTURE_DIMENSION.toFloat() / longest.toFloat())
                val scaled = if (scale < 1f) {
                    Bitmap.createScaledBitmap(
                        cropped,
                        (cropped.width * scale).toInt().coerceAtLeast(1),
                        (cropped.height * scale).toInt().coerceAtLeast(1),
                        true,
                    )
                } else {
                    cropped
                }

                val file = File(cacheDir, SCREEN_CAPTURE_FILE)
                if (file.exists() && !file.delete()) {
                    Log.w("ArifaService", "Could not delete previous screenshot")
                }
                FileOutputStream(file).use { out ->
                    scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
                }
                finishCapture(file.absolutePath)
                if (scaled !== cropped) scaled.recycle()
                cropped.recycle()
                bitmap.recycle()
            } catch (e: Exception) {
                finishCapture(null)
            } finally {
                image.close()
                display?.release()
                r.close()
                try {
                    projection.stop()
                } catch (_: Exception) {
                }
                // Resume always-on wake listening after the screenshot.
                startService(Intent(this@ArifaService, ArifaService::class.java))
            }
        }, handler)
    }

    override fun onDestroy() {
        isRunning = false
        onCaptureDone = null
        try {
            recognizer?.stopListening()
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = null
        handler?.removeCallbacksAndMessages(null)
        thread?.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
