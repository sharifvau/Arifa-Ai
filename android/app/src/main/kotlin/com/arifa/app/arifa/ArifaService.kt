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
    // SpeechRecognizer APIs must be called on the application's main thread.
    private val mainHandler = Handler(Looper.getMainLooper())
    // Exponential backoff for recognizer restarts; capped to avoid a hot loop.
    private var restartDelayMs = 900L
    // Guards against multiple wake emissions from repeated partial results.
    @Volatile
    private var wakeFired = false
    // One capture at a time: MainActivity has a single pending MethodChannel
    // result slot, so a second request would orphan the first (AUDIT M28).
    @Volatile
    private var captureInProgress = false
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
            if (captureInProgress) {
                finishCapture(null)
                stopSelf()
                return START_NOT_STICKY
            }
            captureInProgress = true
            // Screen capture uses only the mediaProjection FGS type. Pause any
            // microphone recognition first so the declared type matches actual
            // use (Android 14 type-specific while-in-use rules).
            stopWakeListening()
            if (!startFgSafe(
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                    "স্ক্রিন ধরছি Emon Bhai...",
                )
            ) {
                captureInProgress = false
                finishCapture(null)
                stopSelf()
                return START_NOT_STICKY
            }
            captureScreen(intent)
            return START_NOT_STICKY
        }

        // A null intent is delivered on a sticky restart. Respect the saved
        // wake flag instead of silently resuming always-on microphone capture.
        val wakeEnabled = getSharedPreferences(
            ArifaNotificationListener.PREFS,
            Context.MODE_PRIVATE,
        ).getBoolean("wake_enabled", true)
        if (!wakeEnabled) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            MainActivity.emit("permission", "RECORD_AUDIO permission নেই Emon Bhai")
            stopSelf()
            return START_NOT_STICKY
        }
        if (!startFgSafe(
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                "Emon Bhai-র জন্য শুনছি ♥",
            )
        ) {
            stopSelf()
            return START_NOT_STICKY
        }
        startWakeListening()
        // Do not request a sticky restart: BootReceiver is the single,
        // user-aware entry point after process death.
        return START_NOT_STICKY
    }

    /** Starts foreground safely; returns false on permission/start failure. */
    private fun startFgSafe(type: Int, text: String): Boolean {
        return try {
            startFg(type, text)
            true
        } catch (e: Exception) {
            Log.e("ArifaService", "startForeground failed", e)
            MainActivity.emit("service", "সার্ভিস চালু হলো না Emon Bhai")
            false
        }
    }

    private fun startFg(type: Int, text: String) {
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /** Stops recognition and cancels any queued restart without a stale reuse. */
    private fun stopWakeListening() {
        mainHandler.removeCallbacksAndMessages(null)
        handler?.removeCallbacksAndMessages(null)
        restartDelayMs = 900L
        wakeFired = false
        destroyRecognizer()
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

    /** Entry point: recognizer creation/start must happen on the main thread. */
    private fun startWakeListening() {
        mainHandler.post {
            if (!isRunning) return@post
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED
            ) {
                MainActivity.emit("permission", "RECORD_AUDIO permission নেই Emon Bhai")
                return@post
            }
            if (recognizer == null) {
                recognizer = SpeechRecognizer.createSpeechRecognizer(this)
                recognizer?.setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {
                        // A healthy session resets the backoff to its base.
                        restartDelayMs = 900L
                    }
                    override fun onBeginningOfSpeech() {}
                    override fun onRmsChanged(rmsdB: Float) {}
                    override fun onBufferReceived(buffer: ByteArray?) {}
                    override fun onEndOfSpeech() {}

                    override fun onError(error: Int) {
                        // Terminal errors (e.g. insufficient permissions) would
                        // otherwise spin in a tight loop. Destroy and back off.
                        MainActivity.emit("wake_error", "SpeechRecognizer error: $error")
                        destroyRecognizer()
                        scheduleRestart(terminal = error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS)
                    }

                    override fun onResults(results: Bundle?) {
                        val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        val heard = list?.firstOrNull().orEmpty()
                        if (heard.isNotBlank() && containsWake(heard)) {
                            fireWake(heard)
                        }
                        scheduleRestart()
                    }

                    override fun onPartialResults(partialResults: Bundle?) {
                        val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        val heard = list?.firstOrNull().orEmpty()
                        if (heard.isNotBlank() && containsWake(heard)) {
                            fireWake(heard)
                            try {
                                recognizer?.stopListening()
                            } catch (_: Exception) {
                            }
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
                destroyRecognizer()
                scheduleRestart()
            }
        }
    }

    /** Emits a wake event at most once per recognition session. */
    private fun fireWake(heard: String) {
        mainHandler.post {
            if (wakeFired) return@post
            wakeFired = true
            MainActivity.emit("wake", heard)
            launchAppOnWake()
        }
    }

    private fun destroyRecognizer() {
        try {
            recognizer?.stopListening()
            recognizer?.destroy()
        } catch (_: Exception) {
        }
        recognizer = null
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

    private fun scheduleRestart(terminal: Boolean = false) {
        if (!isRunning || terminal) return
        wakeFired = false
        val delay = restartDelayMs
        restartDelayMs = minOf(restartDelayMs * 2, 30_000L)
        mainHandler.postDelayed({
            startWakeListening()
        }, delay)
    }

    private fun captureScreen(intent: Intent) {
        val resultCode = intent.getIntExtra("resultCode", 0)
        @Suppress("DEPRECATION")
        val data = intent.getParcelableExtra("data") as? Intent
        if (data == null || resultCode == 0) {
            failCaptureAndRestoreWake()
            return
        }
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = try {
            manager.getMediaProjection(resultCode, data)
        } catch (e: Exception) {
            failCaptureAndRestoreWake()
            return
        }

        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        var reader: ImageReader? = null
        var display: android.hardware.display.VirtualDisplay? = null

        // Single idempotent cleanup for success, denial, exception, timeout and
        // user revocation. Returns true only for the caller that won the race.
        fun cleanup(): Boolean {
            if (!done.compareAndSet(false, true)) return false
            captureInProgress = false
            try { display?.release() } catch (_: Exception) {}
            try { reader?.close() } catch (_: Exception) {}
            try { projection.stop() } catch (_: Exception) {}
            return true
        }

        // Android 14+ can revoke capture at any time; without this callback the
        // reader/display leak and the pending MethodChannel result never returns.
        try {
            projection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    if (cleanup()) {
                        finishCapture(null)
                        restoreWakeListening()
                    }
                }
            }, handler)
        } catch (_: Exception) {
        }

        // Watchdog: if no image ever arrives, fail cleanly instead of hanging.
        handler?.postDelayed({
            if (cleanup()) {
                finishCapture(null)
                restoreWakeListening()
            }
        }, 5000L)

        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi
        try {
            reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
            display = projection.createVirtualDisplay(
                "ArifaScreen", width, height, density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader!!.surface, null, handler,
            )
        } catch (e: Exception) {
            Log.e("ArifaService", "virtual display creation failed", e)
            if (cleanup()) {
                finishCapture(null)
                restoreWakeListening()
            }
            return
        }

        reader!!.setOnImageAvailableListener({ r ->
            val image = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            var path: String? = null
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
                path = file.absolutePath
                if (scaled !== cropped) scaled.recycle()
                cropped.recycle()
                bitmap.recycle()
            } catch (e: Exception) {
                Log.e("ArifaService", "screenshot encode failed", e)
            } finally {
                try { image.close() } catch (_: Exception) {}
            }
            if (cleanup()) {
                finishCapture(path)
                restoreWakeListening()
            }
        }, handler)
    }

    private fun failCaptureAndRestoreWake() {
        finishCapture(null)
        restoreWakeListening()
    }

    /** Restarts the microphone wake service after any capture exit path. */
    private fun restoreWakeListening() {
        try {
            startService(Intent(this@ArifaService, ArifaService::class.java))
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        isRunning = false
        onCaptureDone = null
        mainHandler.removeCallbacksAndMessages(null)
        stopWakeListening()
        handler?.removeCallbacksAndMessages(null)
        thread?.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
