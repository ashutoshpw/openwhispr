package com.openwhispr.feasibility.insertion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SafeInsertionTest {
    @Test
    fun splicesTranscriptAtSelectionAndPreservesBothSides() {
        val target = target(text = "hello world", start = 6, end = 11)

        val decision = planSafeInsertion(target, target, "there")

        assertEquals(
            InsertionDecision.Insert(replacementText = "hello there", insertionEnd = 11),
            decision,
        )
    }

    @Test
    fun insertsAtCursorWithoutDroppingExistingText() {
        val target = target(text = "ab", start = 1, end = 1)

        val decision = planSafeInsertion(target, target, "X")

        assertEquals(InsertionDecision.Insert("aXb", 2), decision)
    }

    @Test
    fun rejectsChangedTargetIdentity() {
        val captured = target(identity = "window-1/node-a")
        val current = target(identity = "window-1/node-b")

        assertEquals(
            InsertionDecision.Reject(RejectionReason.TargetChanged),
            planSafeInsertion(captured, current, "hello"),
        )
    }

    @Test
    fun rejectsChangedTextEvenWhenIdentityIsTheSame() {
        val captured = target(text = "before")
        val current = target(text = "before plus user edit")

        assertEquals(
            InsertionDecision.Reject(RejectionReason.TextChanged),
            planSafeInsertion(captured, current, "hello"),
        )
    }

    @Test
    fun rejectsChangedSelection() {
        val captured = target(start = 1, end = 1)
        val current = target(start = 2, end = 2)

        assertEquals(
            InsertionDecision.Reject(RejectionReason.SelectionChanged),
            planSafeInsertion(captured, current, "hello"),
        )
    }

    @Test
    fun rejectsPasswordFields() {
        val target = target(password = true)

        val decision = planSafeInsertion(target, target, "secret")

        assertEquals(InsertionDecision.Reject(RejectionReason.PasswordField), decision)
    }

    @Test
    fun rejectsRichOrUnsupportedEditors() {
        val target = target(plainTextEditor = false)

        val decision = planSafeInsertion(target, target, "hello")

        assertEquals(InsertionDecision.Reject(RejectionReason.UnsupportedEditor), decision)
    }

    @Test
    fun rejectsBlankTranscript() {
        val target = target()

        val decision = planSafeInsertion(target, target, "")

        assertTrue(decision is InsertionDecision.Reject)
        assertEquals(RejectionReason.EmptyTranscript, (decision as InsertionDecision.Reject).reason)
    }

    private fun target(
        identity: String = "window-1/node-a",
        text: String = "hello",
        start: Int = 5,
        end: Int = 5,
        editable: Boolean = true,
        password: Boolean = false,
        supportsSetText: Boolean = true,
        plainTextEditor: Boolean = true,
    ) = InsertionTarget(
        identity = identity,
        text = text,
        selectionStart = start,
        selectionEnd = end,
        editable = editable,
        password = password,
        supportsSetText = supportsSetText,
        plainTextEditor = plainTextEditor,
    )
}
