import Foundation

/// Pure state transitions for the app/keyboard protocol. Keeping this reducer
/// Foundation-only makes the lifecycle contract testable on a macOS SwiftPM host
/// without booting an iOS simulator.
public enum SessionReducer {
    public static let commandFreshness: TimeInterval = 30
    public static let maximumRememberedNonces = 32

    public static func reduce(_ state: SessionState, _ action: SessionAction) -> SessionState {
        var next = state

        switch action {
        case .hostLaunched:
            next = SessionState()

        case let .activate(sessionID, expiresAt, at):
            guard !sessionID.isEmpty, expiresAt > at else {
                next.lastError = "invalid-activation"
                return next
            }
            next.phase = .ready
            next.sessionID = sessionID
            next.dictationID = nil
            next.activeCommandNonce = nil
            next.appliedCommandNonces = []
            next.result = nil
            next.hostHeartbeatAt = at
            next.sessionExpiresAt = expiresAt
            next.lastError = nil

        case let .heartbeat(sessionID, at):
            guard next.sessionID == sessionID,
                  next.hasActiveSession,
                  let expiresAt = next.sessionExpiresAt,
                  expiresAt > at
            else {
                return next
            }
            next.hostHeartbeatAt = at

        case let .command(command, at):
            apply(command, to: &next, at: at)

        case let .capReached(dictationID, at):
            guard next.phase == .recording,
                  next.dictationID == dictationID,
                  let expiresAt = next.sessionExpiresAt,
                  expiresAt > at
            else {
                return next
            }
            next.phase = .transcribing
            next.lastError = nil

        case let .finish(dictationID, transcript, capReached, at):
            guard next.phase == .transcribing,
                  next.dictationID == dictationID,
                  let sessionID = next.sessionID,
                  let expiresAt = next.sessionExpiresAt,
                  expiresAt > at
            else {
                return next
            }
            next.phase = .completed
            next.activeCommandNonce = nil
            next.result = TranscriptResult(
                resultID: dictationID,
                dictationID: dictationID,
                text: transcript,
                label: "Fixture transcription",
                capReached: capReached
            )
            next.lastError = nil
            next.hostHeartbeatAt = next.hostHeartbeatAt ?? at
            next.sessionID = sessionID

        case let .expire(sessionID, at):
            guard next.sessionID == sessionID, next.hasActiveSession else {
                return next
            }
            next.phase = .expired
            next.dictationID = nil
            next.activeCommandNonce = nil
            next.result = nil
            next.lastError = "session-expired"
            next.hostHeartbeatAt = at
        }

        return next
    }

    private static func apply(_ command: SessionCommand, to state: inout SessionState, at: Date) {
        // Replayed notifications are expected. A previously applied nonce is a
        // successful no-op, including after the keyboard sends a duplicate ack.
        if state.appliedCommandNonces.contains(command.nonce) {
            return
        }

        guard command.schemaVersion == SessionCommand.currentSchemaVersion,
              command.nonce.isEmpty == false,
              command.sessionID == state.sessionID,
              state.hasActiveSession,
              let expiresAt = state.sessionExpiresAt,
              expiresAt > at,
              isFresh(command.issuedAt, at: at)
        else {
            state.lastError = "stale-or-invalid-command"
            return
        }

        switch command.kind {
        case .start:
            guard state.phase == .ready,
                  let dictationID = command.dictationID,
                  !dictationID.isEmpty
            else {
                state.lastError = "start-requires-ready-session"
                return
            }
            state.phase = .recording
            state.dictationID = dictationID
            state.activeCommandNonce = command.nonce
            state.result = nil
            state.lastError = nil
            remember(command.nonce, in: &state)

        case .stop:
            guard state.phase == .recording,
                  command.dictationID == state.dictationID
            else {
                state.lastError = "stop-requires-active-dictation"
                return
            }
            state.phase = .transcribing
            state.activeCommandNonce = command.nonce
            state.lastError = nil
            remember(command.nonce, in: &state)

        case .cancel:
            guard (state.phase == .recording || state.phase == .transcribing || state.phase == .completed),
                  command.dictationID == state.dictationID
            else {
                state.lastError = "cancel-requires-active-dictation"
                return
            }
            state.phase = .ready
            state.dictationID = nil
            state.activeCommandNonce = nil
            state.result = nil
            state.lastError = nil
            remember(command.nonce, in: &state)

        case .acknowledgeResult:
            guard state.phase == .completed,
                  command.dictationID == state.dictationID,
                  command.resultID == state.result?.resultID
            else {
                state.lastError = "acknowledgement-does-not-match-result"
                return
            }
            state.phase = .ready
            state.dictationID = nil
            state.activeCommandNonce = nil
            state.result = nil
            state.lastError = nil
            remember(command.nonce, in: &state)
        }
    }

    private static func isFresh(_ issuedAt: Date, at now: Date) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        return age <= commandFreshness && age >= -5
    }

    private static func remember(_ nonce: String, in state: inout SessionState) {
        state.appliedCommandNonces.append(nonce)
        if state.appliedCommandNonces.count > maximumRememberedNonces {
            state.appliedCommandNonces.removeFirst(state.appliedCommandNonces.count - maximumRememberedNonces)
        }
    }
}
