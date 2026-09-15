package com.openwhispr.feasibility.accessibility

import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicReference

/** In-process handoff only; no exported broadcast or command endpoint is used. */
object AccessibilityServiceRegistry {
    private val service = AtomicReference<WeakReference<OpenWhisprAccessibilityService>?>(null)

    fun bind(value: OpenWhisprAccessibilityService) {
        service.set(WeakReference(value))
    }

    fun unbind(value: OpenWhisprAccessibilityService) {
        service.get()?.get()?.let { current ->
            if (current === value) service.set(null)
        }
    }

    fun current(): OpenWhisprAccessibilityService? = service.get()?.get()
}
