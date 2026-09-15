package com.openwhispr.feasibility.recording

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.openwhispr.feasibility.MainActivity
import com.openwhispr.feasibility.R
import com.openwhispr.feasibility.accessibility.AccessibilityServiceRegistry
import com.openwhispr.feasibility.accessibility.CapturedTarget
import com.openwhispr.feasibility.accessibility.PendingTargetStore
import java.io.ByteArrayOutputStream
import java.util.Arrays
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max

/**
 * Foreground microphone capture for the feasibility spike. There is no network or
 * React Native dependency here: real audio is captured and discarded after the
 * run, while insertion is exercised only by an explicit fixture mode.
 */
@Suppress("DEPRECATION")
class RecordingService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var session: CaptureSession? = null
    private var ownedGeneration = NO_GENERATION

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val generation = intent?.getLongExtra(EXTRA_SESSION_ID, NO_GENERATION) ?: NO_GENERATION
        when (intent?.action) {
            ACTION_START -> handleStart(
                intent.getStringExtra(EXTRA_TARGET_TOKEN),
                intent.getBooleanExtra(EXTRA_FIXTURE_MODE, false),
                generation,
                startId,
            )

            ACTION_STOP -> stopCapture(generation, cancelled = false)
            ACTION_CANCEL -> stopCapture(generation, cancelled = true)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        session?.let { current ->
            cancelSession(
                current,
                "Recording cancelled because the recording service stopped",
                stopService = false,
            )
        }
        if (session == null) {
            activeRegistry.current()?.takeIf { it.generation == ownedGeneration }?.let { marker ->
                if (marker.lifecycle.requestCancel()) {
                    setStatusIfCurrent(
                        marker,
                        "Recording cancelled because the recording service stopped",
                    )
                    activeRegistry.clearIfCurrent(marker)
                }
            }
        }
        mainHandler.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun handleStart(
        token: String?,
        useFixture: Boolean,
        generation: Long,
        startId: Int,
    ) {
        val marker = activeRegistry.current()
        if (
            token == null ||
            generation == NO_GENERATION ||
            marker == null ||
            marker.generation != generation
        ) {
            PendingTargetStore.remove(token)
            return
        }

        val capturedTarget = PendingTargetStore.take(token)
        if (capturedTarget == null) {
            cancelUnclaimedStart(marker, startId, "Recording could not start because the target expired")
            return
        }

        val current = CaptureSession(
            marker = marker,
            target = capturedTarget,
            fixtureMode = useFixture,
            startId = startId,
        )
        session = current
        ownedGeneration = generation

        if (!marker.lifecycle.beginRecording()) {
            cancelSession(current, "Recording start was cancelled")
            return
        }

        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            cancelSession(current, "Microphone permission is required")
            return
        }

        try {
            createNotificationChannel()
            startForegroundCompat(buildNotification(recording = true, generation = generation))
            beginCapture(current)
            setStatusIfCurrent(
                marker,
                if (useFixture) {
                    "Recording microphone; explicit fixture transcript mode is enabled"
                } else {
                    "Recording microphone; audio will be discarded after this spike run"
                },
            )
        } catch (_: SecurityException) {
            cancelSession(current, "The system rejected microphone foreground capture")
        } catch (_: IllegalStateException) {
            cancelSession(current, "Microphone capture is unavailable on this device")
        }
    }

    @SuppressLint("MissingPermission")
    private fun beginCapture(current: CaptureSession) {
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) throw IllegalStateException("AudioRecord buffer is unavailable")

        val bufferSize = max(minBuffer * 2, SAMPLE_RATE / 2)
        val audioRecord = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.MIC)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(bufferSize)
            .build()
        if (audioRecord.state != AudioRecord.STATE_INITIALIZED) {
            audioRecord.release()
            throw IllegalStateException("AudioRecord did not initialize")
        }
        current.recorder.set(audioRecord)
        current.captureExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "openwhispr-feasibility-audio-${current.marker.generation}").apply {
                isDaemon = true
            }
        }
        current.captureExecutor?.execute {
            captureLoop(current, audioRecord, bufferSize)
        }
    }

    private fun captureLoop(
        current: CaptureSession,
        audioRecord: AudioRecord,
        bufferSize: Int,
    ) {
        val buffer = ByteArray(bufferSize)
        var captureFailed = false

        try {
            if (current.lifecycle.currentPhase() != CapturePhase.RECORDING) return
            audioRecord.startRecording()
            scheduleDeadline(current)

            while (current.lifecycle.currentPhase() == CapturePhase.RECORDING) {
                val read = audioRecord.read(buffer, 0, buffer.size)
                if (read > 0) {
                    var keepReading = true
                    synchronized(current.audioBuffer) {
                        if (current.lifecycle.currentPhase() == CapturePhase.RECORDING) {
                            current.audioBuffer.write(buffer, 0, read)
                        } else {
                            keepReading = false
                        }
                    }
                    if (!keepReading) break
                } else if (read < 0) {
                    if (current.lifecycle.currentPhase() == CapturePhase.RECORDING) {
                        captureFailed = true
                        current.lifecycle.requestStop()
                    }
                    break
                }
            }
        } catch (_: IllegalStateException) {
            // A normal stop (including the 120-second cap) releases AudioRecord
            // from another thread. A blocked read can report that release as an
            // IllegalStateException; preserve the captured bytes and let the
            // STOPPING lifecycle complete normally in that case.
            if (current.lifecycle.currentPhase() == CapturePhase.RECORDING) {
                captureFailed = true
                current.lifecycle.requestStop()
            }
        } finally {
            current.deadlineFuture?.cancel(false)
            current.deadlineExecutor.shutdownNow()
            current.recorder.compareAndSet(audioRecord, null)
            releaseRecorder(audioRecord)
        }

        // AccessibilityNodeInfo operations and service teardown stay on the main
        // thread. The worker never waits for that dispatch.
        mainHandler.post {
            finishCapture(current, captureFailed)
        }
    }

    private fun scheduleDeadline(current: CaptureSession) {
        current.deadlineFuture = current.deadlineExecutor.schedule(
            { enforceDeadline(current) },
            MAX_DURATION_MS,
            TimeUnit.MILLISECONDS,
        )
    }

    /** Runs on a separate scheduler so a blocked AudioRecord.read cannot defer the cap. */
    private fun enforceDeadline(current: CaptureSession) {
        if (!isCurrent(current)) return
        if (current.lifecycle.requestStop()) {
            current.reachedCap.set(true)
            stopRecorder(current)
        }
    }

    private fun finishCapture(current: CaptureSession, captureFailed: Boolean) {
        if (!current.lifecycle.claimFinish()) {
            // Cancellation/destruction already owns terminal cleanup. A late worker
            // callback must not publish status or stop a newer session.
            return
        }

        val isCurrent = isCurrent(current)
        if (!isCurrent) {
            clearAudio(current)
            current.target = null
            return
        }

        val insertionStatus = if (captureFailed) {
            "Microphone capture failed; captured audio was discarded"
        } else if (current.fixtureMode) {
            val capturedTarget = current.target
            if (capturedTarget == null) {
                "Fixture transcript skipped because the original target expired"
            } else {
                AccessibilityServiceRegistry.current()?.insertTranscript(
                    capturedTarget,
                    FIXTURE_TRANSCRIPT,
                ) ?: "Fixture transcript skipped because AccessibilityService is unavailable"
            }
        } else if (current.reachedCap.get()) {
            "120-second cap reached; audio was discarded because no transport is configured"
        } else {
            "Audio captured; it was discarded because no transport is configured"
        }
        val capPrefix = if (current.reachedCap.get() && current.fixtureMode) {
            "120-second cap reached; "
        } else {
            ""
        }

        clearAudio(current)
        current.target = null
        current.captureExecutor?.shutdown()
        setStatusIfCurrent(current.marker, capPrefix + insertionStatus)
        activeRegistry.clearIfCurrent(current.marker)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelfResult(current.startId)
    }

    private fun stopCapture(generation: Long, cancelled: Boolean) {
        val marker = activeRegistry.current() ?: return
        if (generation != marker.generation) return
        val current = session
        if (current == null) {
            if (cancelled && marker.lifecycle.requestCancel()) {
                setStatusIfCurrent(marker, "Recording cancelled before capture started")
                activeRegistry.clearIfCurrent(marker)
            }
            return
        }
        if (cancelled) {
            cancelSession(current, "Recording cancelled; captured audio was discarded")
        } else if (current.lifecycle.requestStop()) {
            stopRecorder(current)
        }
    }

    private fun cancelSession(
        current: CaptureSession,
        message: String,
        stopService: Boolean = true,
    ) {
        if (!current.lifecycle.requestCancel()) return
        current.deadlineFuture?.cancel(false)
        current.deadlineExecutor.shutdownNow()
        stopRecorder(current)
        current.captureExecutor?.shutdownNow()
        clearAudio(current)
        current.target = null
        val isCurrent = activeRegistry.current() === current.marker
        if (isCurrent) {
            setStatusIfCurrent(current.marker, message)
            activeRegistry.clearIfCurrent(current.marker)
            stopForeground(STOP_FOREGROUND_REMOVE)
            if (stopService) stopSelfResult(current.startId)
        }
        if (session === current) session = null
    }

    private fun cancelUnclaimedStart(marker: ActiveCapture, startId: Int, message: String) {
        if (marker.lifecycle.requestCancel()) {
            setStatusIfCurrent(marker, message)
            activeRegistry.clearIfCurrent(marker)
            stopSelfResult(startId)
        }
    }

    private fun stopRecorder(current: CaptureSession) {
        current.recorder.getAndSet(null)?.let(::releaseRecorder)
    }

    private fun releaseRecorder(audioRecord: AudioRecord) {
        runCatching { audioRecord.stop() }
        runCatching { audioRecord.release() }
    }

    private fun clearAudio(current: CaptureSession) {
        synchronized(current.audioBuffer) {
            current.audioBuffer.clearAndWipe()
        }
    }

    private fun isCurrent(current: CaptureSession): Boolean =
        activeRegistry.current() === current.marker && session === current

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "OpenWhispr microphone feasibility",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun buildNotification(recording: Boolean, generation: Long): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
        if (recording) {
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_media_pause),
                    "Stop",
                    serviceActionPendingIntent(ACTION_STOP, REQUEST_STOP, generation),
                ).build(),
            )
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                    "Cancel",
                    serviceActionPendingIntent(ACTION_CANCEL, REQUEST_CANCEL, generation),
                ).build(),
            )
        }
        return builder
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle("OpenWhispr Android feasibility")
            .setContentText(
                if (recording) "Microphone capture is active" else "Microphone capture stopped",
            )
            .setContentIntent(openIntent)
            .setOngoing(recording)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun serviceActionPendingIntent(
        action: String,
        requestCode: Int,
        generation: Long,
    ): PendingIntent = PendingIntent.getService(
        this,
        requestCode,
        Intent(this, RecordingService::class.java)
            .setAction(action)
            .putExtra(EXTRA_SESSION_ID, generation),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun setStatusIfCurrent(marker: ActiveCapture, value: String) {
        if (activeRegistry.current() === marker) setStatus(value)
    }

    companion object {
        const val MAX_DURATION_MS = 120_000L
        const val ACTION_START = "com.openwhispr.feasibility.action.START"
        const val ACTION_STOP = "com.openwhispr.feasibility.action.STOP"
        const val ACTION_CANCEL = "com.openwhispr.feasibility.action.CANCEL"
        const val EXTRA_TARGET_TOKEN = "target_token"
        const val EXTRA_FIXTURE_MODE = "fixture_mode"
        const val EXTRA_SESSION_ID = "session_id"
        const val FIXTURE_TRANSCRIPT = "[OpenWhispr fixture transcript] hello from the Android spike"

        private const val NO_GENERATION = -1L
        private const val CHANNEL_ID = "openwhispr-feasibility-microphone"
        private const val NOTIFICATION_ID = 4721
        private const val REQUEST_STOP = 4722
        private const val REQUEST_CANCEL = 4723
        private const val SAMPLE_RATE = 16_000

        private val nextGeneration = AtomicLong(0L)
        private val activeRegistry = ActiveCaptureRegistry()
        private val status = AtomicReference("Microphone is idle")

        fun isRecording(): Boolean = activeRegistry.current()?.lifecycle?.isActive() == true

        fun isRecordingForTarget(identity: String): Boolean =
            activeRegistry.current()?.let { marker ->
                marker.targetIdentity == identity && marker.lifecycle.isActive()
            } == true

        fun statusText(): String = status.get()

        fun startRecording(
            context: Context,
            targetToken: String,
            targetIdentity: String,
            fixtureMode: Boolean,
        ): Boolean {
            val generation = nextGeneration.incrementAndGet()
            val marker = ActiveCapture(
                generation = generation,
                targetIdentity = targetIdentity,
                lifecycle = CaptureLifecycle(generation),
            )
            if (!activeRegistry.reserve(marker)) return false

            val intent = Intent(context, RecordingService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TARGET_TOKEN, targetToken)
                .putExtra(EXTRA_FIXTURE_MODE, fixtureMode)
                .putExtra(EXTRA_SESSION_ID, generation)
            try {
                context.startForegroundService(intent)
                return true
            } catch (_: RuntimeException) {
                PendingTargetStore.remove(targetToken)
                if (marker.lifecycle.requestCancel()) {
                    if (activeRegistry.current() === marker) {
                        status.set("The system rejected the recording service start")
                    }
                    activeRegistry.clearIfCurrent(marker)
                }
                return false
            }
        }

        fun requestStop(context: Context) {
            val generation = activeRegistry.current()?.generation ?: return
            runCatching {
                context.startService(
                    Intent(context, RecordingService::class.java)
                        .setAction(ACTION_STOP)
                        .putExtra(EXTRA_SESSION_ID, generation),
                )
            }
        }

        fun requestCancel(context: Context) {
            val generation = activeRegistry.current()?.generation ?: return
            runCatching {
                context.startService(
                    Intent(context, RecordingService::class.java)
                        .setAction(ACTION_CANCEL)
                        .putExtra(EXTRA_SESSION_ID, generation),
                )
            }
        }

        private fun setStatus(value: String) {
            status.set(value)
        }
    }

    private class CaptureSession(
        val marker: ActiveCapture,
        var target: CapturedTarget?,
        val fixtureMode: Boolean,
        val startId: Int,
    ) {
        val audioBuffer = WipeableAudioBuffer()
        val recorder = AtomicReference<AudioRecord?>(null)
        val deadlineExecutor = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "openwhispr-feasibility-deadline-${marker.generation}").apply {
                isDaemon = true
            }
        }
        var deadlineFuture: ScheduledFuture<*>? = null
        var captureExecutor: ExecutorService? = null
        val reachedCap = AtomicBoolean(false)
        val lifecycle: CaptureLifecycle = marker.lifecycle
    }

    private class WipeableAudioBuffer : ByteArrayOutputStream() {
        fun clearAndWipe() {
            Arrays.fill(buf, 0.toByte())
            reset()
        }
    }
}
