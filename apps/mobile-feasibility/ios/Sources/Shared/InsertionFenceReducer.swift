import Foundation

/// Pure fence transitions used by the App Group store. Claiming is persisted
/// before the keyboard calls insertText. A claimed fence is intentionally not
/// released automatically: if the extension dies after claiming and before
/// insertion, the next instance must require explicit manual recovery rather
/// than risk a duplicate insertion.
public enum InsertionFenceReducer {
    public static func claim(
        existing: InsertionFence?,
        result: TranscriptResult,
        state: SessionState,
        at now: Date,
        claimNonce: String
    ) -> InsertionClaimResult {
        guard state.phase == .completed,
              state.sessionID != nil,
              state.dictationID == result.dictationID,
              state.result == result,
              state.hostIsResponsive(at: now),
              !claimNonce.isEmpty
        else {
            return .unavailable("host-or-result-not-ready")
        }

        if let existing {
            guard existing.schemaVersion == InsertionFence.currentSchemaVersion,
                  existing.resultID == result.resultID,
                  existing.sessionID == state.sessionID,
                  existing.dictationID == result.dictationID
            else {
                return .unavailable("fence-does-not-match-result")
            }

            switch existing.status {
            case .available:
                return .claimed(claimedFence(from: existing, nonce: claimNonce, at: now))
            case .claimed:
                return .alreadyClaimed(existing)
            case .inserted:
                return .alreadyInserted(existing)
            case .cancelled:
                return .unavailable("result-cancelled")
            }
        }

        return .claimed(
            InsertionFence(
                resultID: result.resultID,
                sessionID: state.sessionID ?? "",
                dictationID: result.dictationID,
                status: .claimed,
                claimNonce: claimNonce,
                updatedAt: now
            )
        )
    }

    public static func markInserted(
        _ fence: InsertionFence,
        resultID: String,
        sessionID: String,
        dictationID: String,
        claimNonce: String,
        at now: Date
    ) -> InsertionFence? {
        guard fence.status == .claimed,
              fence.resultID == resultID,
              fence.sessionID == sessionID,
              fence.dictationID == dictationID,
              fence.claimNonce == claimNonce
        else {
            return nil
        }

        var inserted = fence
        inserted.status = .inserted
        inserted.updatedAt = now
        return inserted
    }

    public static func cancel(_ fence: InsertionFence, at now: Date) -> InsertionFence? {
        guard fence.status == .available || fence.status == .claimed else { return nil }
        var cancelled = fence
        cancelled.status = .cancelled
        cancelled.claimNonce = nil
        cancelled.updatedAt = now
        return cancelled
    }

    private static func claimedFence(from fence: InsertionFence, nonce: String, at now: Date) -> InsertionFence {
        var claimed = fence
        claimed.status = .claimed
        claimed.claimNonce = nonce
        claimed.updatedAt = now
        return claimed
    }

}
