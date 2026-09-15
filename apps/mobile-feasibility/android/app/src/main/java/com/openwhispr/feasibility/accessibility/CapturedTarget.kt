package com.openwhispr.feasibility.accessibility

import com.openwhispr.feasibility.insertion.InsertionTarget
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** A short-lived in-process snapshot. It must never be logged or persisted. */
data class CapturedTarget(
    val identity: String,
    val windowId: Int,
    val packageName: String,
    val className: String,
    val text: String,
    val selectionStart: Int,
    val selectionEnd: Int,
    val editable: Boolean,
    val password: Boolean,
    val supportsSetText: Boolean,
    val plainTextEditor: Boolean,
) {
    fun asInsertionTarget(): InsertionTarget = InsertionTarget(
        identity = identity,
        text = text,
        selectionStart = selectionStart,
        selectionEnd = selectionEnd,
        editable = editable,
        password = password,
        supportsSetText = supportsSetText,
        plainTextEditor = plainTextEditor,
    )
}

/**
 * Bridges the accessibility service and the foreground service without putting
 * target text into an Intent or persistent storage. Entries are removed by take,
 * remove, or clear; a recording can never reuse an old target token.
 */
object PendingTargetStore {
    private val entries = ConcurrentHashMap<String, CapturedTarget>()

    fun put(target: CapturedTarget): String {
        val token = UUID.randomUUID().toString()
        entries[token] = target
        return token
    }

    fun take(token: String): CapturedTarget? = entries.remove(token)

    fun remove(token: String?) {
        if (token != null) entries.remove(token)
    }

    fun clear() {
        entries.clear()
    }
}
