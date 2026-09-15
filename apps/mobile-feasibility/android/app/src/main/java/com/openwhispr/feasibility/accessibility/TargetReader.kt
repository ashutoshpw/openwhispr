package com.openwhispr.feasibility.accessibility

import android.graphics.Rect
import android.os.Build
import android.view.accessibility.AccessibilityNodeInfo

/** Conservative extraction of plain editable targets from the active window. */
object TargetReader {
    private val plainEditorClasses = setOf(
        "android.widget.EditText",
        "android.widget.AutoCompleteTextView",
        "android.widget.MultiAutoCompleteTextView",
        "com.google.android.material.textfield.TextInputEditText",
    )

    fun capture(node: AccessibilityNodeInfo): CapturedTarget? {
        val text = node.text?.toString() ?: ""
        val start = node.textSelectionStart
        val end = node.textSelectionEnd
        if (start < 0 || end < 0 || start > text.length || end > text.length || end < start) {
            return null
        }

        val className = node.className?.toString() ?: return null
        val supportsSetText = node.actionList.any { action ->
            action.id == AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT.id
        }
        val plainTextEditor = isSupportedPlainEditor(className)
        val packageName = node.packageName?.toString() ?: ""

        return CapturedTarget(
            identity = identity(node, packageName, className),
            windowId = node.windowId,
            packageName = packageName,
            className = className,
            text = text,
            selectionStart = start,
            selectionEnd = end,
            editable = node.isEditable,
            password = node.isPassword,
            supportsSetText = supportsSetText,
            plainTextEditor = plainTextEditor,
        )
    }

    private fun isSupportedPlainEditor(className: String): Boolean {
        if (className in plainEditorClasses) return true
        val lower = className.lowercase()
        if (
            "webview" in lower ||
            "rich" in lower ||
            "html" in lower ||
            "markdown" in lower ||
            "codeeditor" in lower ||
            "compose" in lower
        ) {
            return false
        }
        // Unknown editors are rejected until a device test explicitly approves them.
        return false
    }

    private fun identity(
        node: AccessibilityNodeInfo,
        packageName: String,
        className: String,
    ): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            node.uniqueId?.takeIf { it.isNotEmpty() }?.let {
                return "unique:${node.windowId}|$packageName|$it"
            }
        }

        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val viewId = node.viewIdResourceName.orEmpty()
        return buildString {
            append(node.windowId)
            append('|')
            append(packageName)
            append('|')
            append(className)
            append('|')
            append(viewId)
            append('|')
            append(bounds.left)
            append(',')
            append(bounds.top)
            append(',')
            append(bounds.right)
            append(',')
            append(bounds.bottom)
        }
    }
}
