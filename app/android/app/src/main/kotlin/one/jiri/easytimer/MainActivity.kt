package one.jiri.easytimer

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var soundPool: SoundPool? = null
    private var alarmSound = 0
    private var endSound = 0
    private var alarmStream = 0
    private var endStream = 0
    private var gain = 1f
    private var ready = false
    private var pendingLoad: MethodChannel.Result? = null
    private val loadedSounds = mutableSetOf<Int>()
    private val temporarySounds = mutableListOf<File>()
    private val handler = Handler(Looper.getMainLooper())
    private val loadTimeout = Runnable { releaseAudio() }
    // Alarm deadlines must still expire while the device sleeps.
    private val playback = PlaybackPolicy(SystemClock::elapsedRealtime)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Hardware keys should adjust the next beep even while audio is idle.
        volumeControlStream = AudioManager.STREAM_MUSIC
        updateOrientation(resources.configuration)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        updateOrientation(newConfig)
    }

    private fun updateOrientation(configuration: Configuration) {
        val orientation = if (configuration.smallestScreenWidthDp < 600) {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        if (requestedOrientation != orientation) requestedOrientation = orientation
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "easytimer/platform")
            .also { it.setMethodCallHandler(::handleCall) }
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(call.arguments, result)
            "playAlarm" -> play(call.arguments, end = false, result)
            "playEnd" -> play(call.arguments, end = true, result)
            "beginWorkout" -> beginWorkout(call.arguments, result)
            "cancelAlarm" -> cancel(call.arguments, alarmOnly = true, result)
            "stop" -> cancel(call.arguments, alarmOnly = false, result)
            "setVolume" -> {
                val value = call.arguments as? Number
                if (value == null || !value.toDouble().isFinite()) {
                    result.error("invalid_arguments", "Expected a finite volume gain", null)
                    return
                }
                gain = value.toDouble().coerceIn(0.0, 1.0).toFloat()
                for (stream in intArrayOf(alarmStream, endStream)) {
                    if (stream != 0) soundPool?.setVolume(stream, gain, gain)
                }
                result.success(null)
            }
            "keepAwake" -> {
                val enabled = call.arguments as? Boolean
                if (enabled == null) {
                    result.error("invalid_arguments", "Expected a boolean", null)
                    return
                }
                keepAwake(enabled)
                result.success(null)
            }
            "dispose" -> {
                releaseAudio()
                keepAwake(false)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initialize(arguments: Any?, result: MethodChannel.Result) {
        releaseAudio()
        val sounds = arguments as? Map<*, *>
        val alarm = sounds?.get("alarm") as? ByteArray
        val end = sounds?.get("end") as? ByteArray
        if (alarm == null || alarm.isEmpty() || end == null || end.isEmpty()) {
            result.success(false)
            return
        }
        pendingLoad = result
        try {
            val pool = SoundPool.Builder()
                .setMaxStreams(1)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .build()
            soundPool = pool
            pool.setOnLoadCompleteListener { source, sample, status ->
                // A previous pool can finish loading after reinitialization or disposal.
                if (source !== soundPool || pendingLoad == null) return@setOnLoadCompleteListener
                if (status != 0) {
                    releaseAudio()
                } else {
                    loadedSounds.add(sample)
                    if (alarmSound in loadedSounds && endSound in loadedSounds) {
                        ready = true
                        handler.removeCallbacks(loadTimeout)
                        deleteTemporarySounds()
                        val response = pendingLoad
                        pendingLoad = null
                        response?.success(true)
                    }
                }
            }
            alarmSound = loadSound(pool, alarm)
            endSound = loadSound(pool, end)
            if (alarmSound == 0 || endSound == 0) {
                releaseAudio()
            } else {
                handler.postDelayed(loadTimeout, 10_000)
            }
        } catch (_: Exception) {
            releaseAudio()
        }
    }

    private fun loadSound(pool: SoundPool, bytes: ByteArray): Int {
        val file = File.createTempFile("easytimer-", ".wav", cacheDir)
        temporarySounds.add(file)
        file.writeBytes(bytes)
        return pool.load(file.absolutePath, 1)
    }

    private fun play(arguments: Any?, end: Boolean, result: MethodChannel.Result) {
        val request = PlaybackRequest.fromArguments(arguments)
        if (request == null) {
            result.error("invalid_arguments", "Expected eventId, generation, alarmGeneration, plannedAtMs and deadlineMs", null)
            return
        }
        val pending = playback.receive(request, end)
        if (pending == null) {
            result.success(null)
            return
        }
        val pool = soundPool
        val sample = if (end) endSound else alarmSound
        val loops = if (end) 2 else 0
        val startedAt = playback.start(pending) {
            if (pool == null || !ready) return@start false
            val stream = try {
                pool.play(sample, gain, gain, 1, loops, 1f)
            } catch (_: RuntimeException) {
                return@start false
            }
            if (stream == 0) return@start false
            alarmStream = if (end) 0 else stream
            endStream = if (end) stream else 0
            true
        }
        result.success(startedAt?.let { mapOf("startedAtMs" to it) })
    }

    private fun beginWorkout(arguments: Any?, result: MethodChannel.Result) {
        val generation = PlaybackGeneration.fromArguments(arguments)
        if (generation == null) {
            result.error("invalid_arguments", "Expected generation and alarmGeneration", null)
            return
        }
        playback.beginWorkout(generation, ::stopAlarm)
        result.success(null)
    }

    private fun cancel(arguments: Any?, alarmOnly: Boolean, result: MethodChannel.Result) {
        val generation = PlaybackGeneration.fromArguments(arguments)
        if (generation == null) {
            result.error("invalid_arguments", "Expected generation and alarmGeneration", null)
            return
        }
        playback.cancel(generation, alarmOnly) {
            if (alarmOnly) {
                stopAlarm()
            } else {
                stopAudio()
            }
        }
        result.success(null)
    }

    private fun stopAlarm() {
        if (alarmStream != 0) soundPool?.stop(alarmStream)
        alarmStream = 0
    }

    private fun stopAudio() {
        stopAlarm()
        if (endStream != 0) soundPool?.stop(endStream)
        endStream = 0
    }

    private fun deleteTemporarySounds() {
        temporarySounds.forEach { it.delete() }
        temporarySounds.clear()
    }

    private fun releaseAudio() {
        playback.invalidate()
        handler.removeCallbacks(loadTimeout)
        ready = false
        stopAudio()
        soundPool?.setOnLoadCompleteListener(null)
        soundPool?.release()
        soundPool = null
        alarmSound = 0
        endSound = 0
        loadedSounds.clear()
        deleteTemporarySounds()
        val response = pendingLoad
        pendingLoad = null
        response?.success(false)
    }

    private fun keepAwake(enabled: Boolean) {
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        releaseAudio()
        keepAwake(false)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        releaseAudio()
        keepAwake(false)
        super.onDestroy()
    }
}
