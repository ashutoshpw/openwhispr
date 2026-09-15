package com.openwhispr.feasibility.accessibility

import android.annotation.SuppressLint
import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.TextView
import com.openwhispr.feasibility.AppPreferences
import com.openwhispr.feasibility.R
import com.openwhispr.feasibility.insertion.InsertionDecision
import com.openwhispr.feasibility.recording.RecordingService

@SuppressLint("SetTextI18n")
@Suppress("DEPRECATION")
class OpenWhisprAccessibilityService : AccessibilityService() {
    private lateinit var windowManager: WindowManager
    private var overlay: TextView? = null
    private var focusedTarget: CapturedTarget? = null
    private var keyboardVisible = false
    private var status: String = "Accessibility service is starting"

    override fun onServiceConnected() {
        super.onServiceConnected()
        windowManager = getSystemService(WindowManager::class.java)
        serviceInfo = serviceInfo.apply {
            eventTypes =
                AccessibilityEvent.TYPE_VIEW_FOCUSED or
                    AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                    AccessibilityEvent.TYPE_WINDOWS_CHANGED or
                    AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            notificationTimeout = 100
            flags = flags or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }
        AccessibilityServiceRegistry.bind(this)
        status = "Accessibility service connected"
        refreshTargetAndOverlay()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        refreshTargetAndOverlay()
    }

    override fun onInterrupt() {
        RecordingService.requestCancel(this)
        status = "Accessibility service interrupted"
        hideOverlay()
    }

    override fun onDestroy() {
        RecordingService.requestCancel(this)
        hideOverlay()
        AccessibilityServiceRegistry.unbind(this)
        PendingTargetStore.clear()
        super.onDestroy()
    }

    fun statusText(): String = status

    /** Called only by the in-process foreground recording service. */
    fun insertTranscript(captured: CapturedTarget, transcript: String): String {
        val window = findWindow(captured.windowId)
            ?: return "Insertion skipped: original window is no longer available"
        if (!window.isActive && !window.isFocused) {
            return "Insertion skipped: original target window is no longer active"
        }
        val root = window.root ?: return "Insertion skipped: original window content is unavailable"
        val current = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (current == null) {
            root.recycle()
            return "Insertion skipped: editable focus changed"
        }

        return try {
            val currentTarget = TargetReader.capture(current)
                ?: return "Insertion skipped: current target cannot be safely read"
            val decision = com.openwhispr.feasibility.insertion.planSafeInsertion(
                captured.asInsertionTarget(),
                currentTarget.asInsertionTarget(),
                transcript,
            )
            when (decision) {
                is InsertionDecision.Reject ->
                    "Insertion skipped: ${decision.reason.name}"

                is InsertionDecision.Insert -> {
                    val arguments = Bundle().apply {
                        putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                            decision.replacementText,
                        )
                    }
                    val inserted = current.performAction(
                        AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT.id,
                        arguments,
                    )
                    if (!inserted) {
                        "Insertion failed: target rejected ACTION_SET_TEXT"
                    } else {
                        // ACTION_SET_TEXT replaces the complete field. Cursor placement is
                        // best effort because some editors reject ACTION_SET_SELECTION.
                        val selectionArguments = Bundle().apply {
                            putInt(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT,
                                decision.insertionEnd,
                            )
                            putInt(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT,
                                decision.insertionEnd,
                            )
                        }
                        current.performAction(
                            AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_SELECTION.id,
                            selectionArguments,
                        )
                        "Inserted transcript into the verified editable target"
                    }
                }
            }
        } finally {
            current.recycle()
            root.recycle()
        }
    }

    private fun refreshTargetAndOverlay() {
        val windows = runCatching { windows }.getOrDefault(emptyList())
        keyboardVisible = windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        focusedTarget = findFocusedTarget(windows)
        val target = focusedTarget
        val recordingLostTarget = RecordingService.isRecording() &&
            (
                !keyboardVisible ||
                    target == null ||
                    !isSafeTarget(target) ||
                    !RecordingService.isRecordingForTarget(target.identity)
                )
        if (recordingLostTarget) {
            RecordingService.requestCancel(this)
            status = "Recording cancelled because focus or the keyboard changed"
        } else if (target == null) {
            status = if (keyboardVisible) {
                "Keyboard visible; no supported editable target"
            } else {
                "Waiting for an editable field and keyboard"
            }
        } else if (!isSafeTarget(target)) {
            status = "Editable target detected but insertion is unsupported for this field"
        } else {
            status = "Verified editable target ready"
        }
        if (recordingLostTarget) {
            hideOverlay()
        } else if (shouldShowOverlay(target)) {
            showOverlay()
        } else {
            hideOverlay()
        }
        updateOverlayForRecording()
    }

    private fun findFocusedTarget(windows: List<AccessibilityWindowInfo>): CapturedTarget? {
        val candidates = windows
            .asSequence()
            .filter { it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .sortedWith(
                compareByDescending<AccessibilityWindowInfo> { it.isActive }
                    .thenByDescending { it.isFocused },
            )
            .toList()
        for (window in candidates) {
            val root = window.root ?: continue
            val node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            if (node == null) {
                root.recycle()
                continue
            }
            try {
                if (node.isFocused && node.isEditable) {
                    TargetReader.capture(node)?.let { return it }
                }
            } finally {
                node.recycle()
                root.recycle()
            }
        }
        val root = rootInActiveWindow ?: return null
        val node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: run {
            root.recycle()
            return null
        }
        return try {
            if (!node.isFocused || !node.isEditable) null else TargetReader.capture(node)
        } finally {
            node.recycle()
            root.recycle()
        }
    }

    private fun findWindow(windowId: Int): AccessibilityWindowInfo? =
        runCatching { windows.firstOrNull { it.id == windowId && it.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD } }
            .getOrNull()

    private fun isSafeTarget(target: CapturedTarget): Boolean =
        target.editable &&
            !target.password &&
            target.supportsSetText &&
            target.plainTextEditor

    private fun shouldShowOverlay(target: CapturedTarget?): Boolean =
        target != null &&
            isSafeTarget(target) &&
            keyboardVisible &&
            Settings.canDrawOverlays(this)

    private fun showOverlay() {
        if (overlay != null) return
        val view = TextView(this).apply {
            text = "Mic"
            textSize = 12f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            isFocusable = false
            isFocusableInTouchMode = false
            isClickable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            contentDescription = "OpenWhispr microphone. Double tap to start or stop recording."
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.rgb(36, 89, 214))
            }
            setOnClickListener { onOverlayClicked() }
            setOnLongClickListener {
                if (RecordingService.isRecording()) {
                    RecordingService.requestCancel(this@OpenWhisprAccessibilityService)
                    status = "Cancelling microphone capture"
                    updateOverlayForRecording()
                    scheduleRecordingUiRefresh()
                    true
                } else {
                    false
                }
            }
        }
        val size = (64 * resources.displayMetrics.density).toInt()
        val params = WindowManager.LayoutParams(
            size,
            size,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.END
            x = (16 * resources.displayMetrics.density).toInt()
            y = (160 * resources.displayMetrics.density).toInt()
        }
        try {
            windowManager.addView(view, params)
            overlay = view
        } catch (_: SecurityException) {
            status = "Overlay permission is required before showing the microphone"
        } catch (_: WindowManager.BadTokenException) {
            status = "The system rejected the floating microphone window"
        }
    }

    private fun hideOverlay() {
        overlay?.let { view ->
            runCatching { windowManager.removeView(view) }
        }
        overlay = null
    }

    private fun updateOverlayForRecording() {
        overlay?.let { view ->
            val recording = RecordingService.isRecording()
            view.text = if (recording) "Stop" else "Mic"
            view.contentDescription = if (recording) {
                "OpenWhispr microphone. Double tap to stop recording."
            } else {
                "OpenWhispr microphone. Double tap to start recording."
            }
            (view.background as? GradientDrawable)?.setColor(
                if (recording) Color.rgb(190, 44, 56) else Color.rgb(36, 89, 214),
            )
        }
    }

    private fun onOverlayClicked() {
        if (RecordingService.isRecording()) {
            RecordingService.requestStop(this)
            updateOverlayForRecording()
            scheduleRecordingUiRefresh()
            return
        }
        val target = focusedTarget
        if (target == null || !isSafeTarget(target)) {
            status = "Recording needs a supported editable target"
            return
        }

        val token = PendingTargetStore.put(target)
        val fixture = getSharedPreferences(AppPreferences.NAME, Context.MODE_PRIVATE)
            .getBoolean(AppPreferences.FIXTURE_MODE, false)
        val started = RecordingService.startRecording(this, token, target.identity, fixture)
        if (!started) {
            PendingTargetStore.remove(token)
            status = "Recording is already active"
        } else {
            status = if (fixture) {
                "Recording with explicit fixture transcript mode"
            } else {
                "Recording from the microphone"
            }
            updateOverlayForRecording()
        }
    }

    private fun scheduleRecordingUiRefresh() {
        overlay?.postDelayed({
            if (overlay != null) {
                updateOverlayForRecording()
                if (!RecordingService.isRecording()) refreshTargetAndOverlay()
            }
        }, RECORDING_UI_REFRESH_MS)
    }

    companion object {
        private const val RECORDING_UI_REFRESH_MS = 500L
    }
}
