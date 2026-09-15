package com.openwhispr.feasibility.recording

import java.util.concurrent.atomic.AtomicReference

internal enum class CapturePhase {
    STARTING,
    RECORDING,
    STOPPING,
    CANCELLED,
    FINISHED,
}

/** Android-free state machine used to fence late worker completion. */
internal class CaptureLifecycle(val generation: Long) {
    private val phase = AtomicReference(CapturePhase.STARTING)

    fun currentPhase(): CapturePhase = phase.get()

    fun beginRecording(): Boolean = phase.compareAndSet(
        CapturePhase.STARTING,
        CapturePhase.RECORDING,
    )

    fun requestStop(): Boolean = phase.compareAndSet(
        CapturePhase.RECORDING,
        CapturePhase.STOPPING,
    )

    fun requestCancel(): Boolean {
        while (true) {
            when (val current = phase.get()) {
                CapturePhase.CANCELLED,
                CapturePhase.FINISHED,
                -> return false

                CapturePhase.STARTING,
                CapturePhase.RECORDING,
                CapturePhase.STOPPING,
                -> if (phase.compareAndSet(current, CapturePhase.CANCELLED)) return true
            }
        }
    }

    /** Only a non-cancelled stopping worker may publish completion. */
    fun claimFinish(): Boolean = phase.compareAndSet(
        CapturePhase.STOPPING,
        CapturePhase.FINISHED,
    )

    fun isActive(): Boolean = when (phase.get()) {
        CapturePhase.STARTING,
        CapturePhase.RECORDING,
        CapturePhase.STOPPING,
        -> true

        CapturePhase.CANCELLED,
        CapturePhase.FINISHED,
        -> false
    }
}

internal data class ActiveCapture(
    val generation: Long,
    val targetIdentity: String,
    val lifecycle: CaptureLifecycle,
)

/** Compare-and-set ownership prevents an old worker from clearing a new run. */
internal class ActiveCaptureRegistry {
    private val active = AtomicReference<ActiveCapture?>(null)

    fun reserve(capture: ActiveCapture): Boolean = active.compareAndSet(null, capture)

    fun current(): ActiveCapture? = active.get()

    fun clearIfCurrent(capture: ActiveCapture): Boolean = active.compareAndSet(capture, null)
}
