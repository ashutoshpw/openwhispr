package com.openwhispr.feasibility.recording

import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureLifecycleTest {
    @Test
    fun cancellationPreventsLateWorkerCompletion() {
        val lifecycle = CaptureLifecycle(generation = 1L)

        assertTrue(lifecycle.beginRecording())
        assertTrue(lifecycle.requestCancel())
        assertFalse(lifecycle.claimFinish())
        assertFalse(lifecycle.isActive())
    }

    @Test
    fun deadlineStopCanBeClaimedExactlyOnce() {
        val lifecycle = CaptureLifecycle(generation = 2L)

        assertTrue(lifecycle.beginRecording())
        assertTrue(lifecycle.requestStop())
        assertTrue(lifecycle.claimFinish())
        assertFalse(lifecycle.claimFinish())
        assertFalse(lifecycle.isActive())
    }

    @Test
    fun staleGenerationCannotClearNewCapture() {
        val registry = ActiveCaptureRegistry()
        val old = ActiveCapture(3L, "old", CaptureLifecycle(3L))
        val current = ActiveCapture(4L, "current", CaptureLifecycle(4L))

        assertTrue(registry.reserve(old))
        assertTrue(registry.clearIfCurrent(old))
        assertTrue(registry.reserve(current))
        assertFalse(registry.clearIfCurrent(old))
        assertSame(current, registry.current())
    }
}
