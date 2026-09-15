package com.openwhispr.feasibility.insertion

/**
 * A small, Android-free model of the target captured by the accessibility service.
 *
 * Text is deliberately kept in memory only. Callers must not write these values to
 * logs, preferences, notifications, or intents that leave the app process.
 */
data class InsertionTarget(
    val identity: String,
    val text: String,
    val selectionStart: Int,
    val selectionEnd: Int,
    val editable: Boolean,
    val password: Boolean,
    val supportsSetText: Boolean,
    val plainTextEditor: Boolean,
)

sealed interface InsertionDecision {
    data class Insert(val replacementText: String, val insertionEnd: Int) : InsertionDecision

    data class Reject(val reason: RejectionReason) : InsertionDecision
}

enum class RejectionReason {
    EmptyTranscript,
    TargetChanged,
    TextChanged,
    SelectionChanged,
    InvalidSelection,
    NotEditable,
    PasswordField,
    UnsupportedEditor,
}

/**
 * Plans a whole-field ACTION_SET_TEXT operation without silently writing into a
 * changed target. ACTION_SET_TEXT replaces the complete field, so the original
 * prefix and suffix are spliced around the transcript first.
 */
fun planSafeInsertion(
    captured: InsertionTarget,
    current: InsertionTarget,
    transcript: String,
): InsertionDecision {
    if (transcript.isEmpty()) return InsertionDecision.Reject(RejectionReason.EmptyTranscript)
    if (captured.identity != current.identity) {
        return InsertionDecision.Reject(RejectionReason.TargetChanged)
    }
    if (captured.text != current.text) {
        return InsertionDecision.Reject(RejectionReason.TextChanged)
    }
    if (
        captured.selectionStart != current.selectionStart ||
        captured.selectionEnd != current.selectionEnd
    ) {
        return InsertionDecision.Reject(RejectionReason.SelectionChanged)
    }
    if (
        captured.selectionStart < 0 ||
        captured.selectionEnd < captured.selectionStart ||
        captured.selectionEnd > captured.text.length
    ) {
        return InsertionDecision.Reject(RejectionReason.InvalidSelection)
    }
    if (!captured.editable || !current.editable) {
        return InsertionDecision.Reject(RejectionReason.NotEditable)
    }
    if (captured.password || current.password) {
        return InsertionDecision.Reject(RejectionReason.PasswordField)
    }
    if (!captured.supportsSetText || !current.supportsSetText) {
        return InsertionDecision.Reject(RejectionReason.UnsupportedEditor)
    }
    if (!captured.plainTextEditor || !current.plainTextEditor) {
        return InsertionDecision.Reject(RejectionReason.UnsupportedEditor)
    }

    val prefix = captured.text.substring(0, captured.selectionStart)
    val suffix = captured.text.substring(captured.selectionEnd)
    val replacement = prefix + transcript + suffix
    return InsertionDecision.Insert(
        replacementText = replacement,
        insertionEnd = captured.selectionStart + transcript.length,
    )
}
