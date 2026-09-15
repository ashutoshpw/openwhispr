import Foundation
import XCTest
@testable import OpenWhisprIOSFeasibilityCore

final class SessionReducerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let sessionID = "session-1"
    private let dictationID = "dictation-1"

    private func activatedState() -> SessionState {
        SessionReducer.reduce(
            SessionState(),
            .activate(
                sessionID: sessionID,
                expiresAt: start.addingTimeInterval(600),
                at: start
            )
        )
    }

    private func command(
        _ kind: SessionCommandKind,
        nonce: String,
        dictationID: String? = nil,
        resultID: String? = nil,
        issuedAt: Date? = nil
    ) -> SessionCommand {
        SessionCommand(
            kind: kind,
            nonce: nonce,
            sessionID: sessionID,
            dictationID: dictationID,
            resultID: resultID,
            issuedAt: issuedAt ?? start
        )
    }

    private func completedState() -> SessionState {
        var state = activatedState()
        state = SessionReducer.reduce(
            state,
            .command(command(.start, nonce: "start", dictationID: dictationID), at: start)
        )
        state = SessionReducer.reduce(
            state,
            .command(command(.stop, nonce: "stop", dictationID: dictationID), at: start.addingTimeInterval(1))
        )
        return SessionReducer.reduce(
            state,
            .finish(
                dictationID: dictationID,
                transcript: "[Fixture transcription] hello",
                capReached: false,
                at: start.addingTimeInterval(2)
            )
        )
    }

    func testStartStopFinishAndAcknowledgementAreIdempotent() {
        var state = activatedState()
        state = SessionReducer.reduce(
            state,
            .command(command(.start, nonce: "start-nonce", dictationID: dictationID), at: start)
        )
        XCTAssertEqual(state.phase, .recording)
        XCTAssertEqual(state.dictationID, dictationID)

        let duplicateStart = SessionReducer.reduce(
            state,
            .command(command(.start, nonce: "start-nonce", dictationID: dictationID), at: start)
        )
        XCTAssertEqual(duplicateStart, state)

        state = SessionReducer.reduce(
            state,
            .command(command(.stop, nonce: "stop-nonce", dictationID: dictationID), at: start)
        )
        state = SessionReducer.reduce(
            state,
            .finish(
                dictationID: dictationID,
                transcript: "[Fixture transcription] hello",
                capReached: false,
                at: start.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.result?.label, "Fixture transcription")

        let acknowledge = command(
            .acknowledgeResult,
            nonce: "ack-nonce",
            dictationID: dictationID,
            resultID: dictationID
        )
        state = SessionReducer.reduce(state, .command(acknowledge, at: start.addingTimeInterval(2)))
        XCTAssertEqual(state.phase, .ready)
        XCTAssertNil(state.result)

        let duplicateAcknowledgement = SessionReducer.reduce(
            state,
            .command(acknowledge, at: start.addingTimeInterval(2))
        )
        XCTAssertEqual(duplicateAcknowledgement, state)
    }

    func testCancelEndsOnlyTheCurrentDictation() {
        var state = activatedState()
        state = SessionReducer.reduce(
            state,
            .command(command(.start, nonce: "start", dictationID: dictationID), at: start)
        )
        state = SessionReducer.reduce(
            state,
            .command(command(.cancel, nonce: "cancel", dictationID: dictationID), at: start.addingTimeInterval(1))
        )

        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.sessionID, sessionID)
        XCTAssertNil(state.dictationID)
        XCTAssertNil(state.result)
        XCTAssertTrue(state.hostIsResponsive(at: start.addingTimeInterval(1)))
    }

    func testQueuedStartStopCancelPreservesOrderAndCancellation() {
        let startCommand = command(.start, nonce: "start", dictationID: dictationID)
        let stopCommand = command(.stop, nonce: "stop", dictationID: dictationID)
        let cancelCommand = command(.cancel, nonce: "cancel", dictationID: dictationID)
        var queue = SessionCommandQueue()
        queue.enqueue(startCommand)
        queue.enqueue(stopCommand)
        queue.enqueue(cancelCommand)
        queue.enqueue(stopCommand)

        XCTAssertEqual(queue.commands.map(\.nonce), ["start", "stop", "cancel"])
        XCTAssertEqual(queue.next, startCommand)

        var state = activatedState()
        for command in [startCommand, stopCommand, cancelCommand] {
            state = SessionReducer.reduce(
                state,
                .command(command, at: start.addingTimeInterval(1))
            )
            XCTAssertTrue(queue.acknowledge(nonce: command.nonce))
        }
        XCTAssertEqual(state.phase, .ready)
        XCTAssertNil(state.dictationID)
        XCTAssertNil(state.result)
        XCTAssertTrue(queue.commands.isEmpty)
    }

    func testCapEndsDictationAndPreservesActivationSession() {
        var state = activatedState()
        state = SessionReducer.reduce(
            state,
            .command(command(.start, nonce: "start", dictationID: dictationID), at: start)
        )
        state = SessionReducer.reduce(
            state,
            .capReached(dictationID: dictationID, at: start.addingTimeInterval(120))
        )
        XCTAssertEqual(state.phase, .transcribing)
        state = SessionReducer.reduce(
            state,
            .heartbeat(sessionID: sessionID, at: start.addingTimeInterval(121))
        )

        state = SessionReducer.reduce(
            state,
            .finish(
                dictationID: dictationID,
                transcript: "[Fixture transcription] capped",
                capReached: true,
                at: start.addingTimeInterval(121)
            )
        )
        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.result?.capReached, true)
        XCTAssertEqual(state.sessionID, sessionID)
        XCTAssertTrue(state.hostIsResponsive(at: start.addingTimeInterval(121)))
    }

    func testStaleAndWrongSessionCommandsFailClosed() {
        let stale = SessionCommand(
            kind: .start,
            nonce: "stale",
            sessionID: sessionID,
            dictationID: dictationID,
            issuedAt: start.addingTimeInterval(-SessionReducer.commandFreshness - 1)
        )
        let staleState = SessionReducer.reduce(
            activatedState(),
            .command(stale, at: start)
        )
        XCTAssertEqual(staleState.phase, .ready)
        XCTAssertEqual(staleState.lastError, "stale-or-invalid-command")

        let wrongSession = SessionCommand(
            kind: .start,
            nonce: "wrong-session",
            sessionID: "other-session",
            dictationID: dictationID,
            issuedAt: start
        )
        let wrongSessionState = SessionReducer.reduce(
            activatedState(),
            .command(wrongSession, at: start)
        )
        XCTAssertEqual(wrongSessionState.phase, .ready)
        XCTAssertEqual(wrongSessionState.lastError, "stale-or-invalid-command")
    }

    func testHostLaunchCreatesAReactivationBoundaryAndExpiryInvalidates() {
        var state = activatedState()
        XCTAssertTrue(state.hostIsResponsive(at: start.addingTimeInterval(5)))
        XCTAssertFalse(state.hostIsResponsive(at: start.addingTimeInterval(6)))
        state = SessionReducer.reduce(
            state,
            .expire(sessionID: sessionID, at: start.addingTimeInterval(601))
        )
        XCTAssertEqual(state.phase, .expired)
        XCTAssertFalse(state.hostIsResponsive(at: start.addingTimeInterval(601)))

        state = SessionReducer.reduce(state, .hostLaunched)
        XCTAssertEqual(state, SessionState())
    }

    func testInsertionFenceIsDurableAtMostOnceAndHeartbeatBound() {
        let state = completedState()
        let result = try! XCTUnwrap(state.result)
        let claim = InsertionFenceReducer.claim(
            existing: nil,
            result: result,
            state: state,
            at: start.addingTimeInterval(3),
            claimNonce: "claim-1"
        )
        let claimed: InsertionFence
        if case let .claimed(fence) = claim {
            claimed = fence
        } else {
            XCTFail("first result claim should succeed")
            return
        }

        if case .alreadyClaimed(_) = InsertionFenceReducer.claim(
            existing: claimed,
            result: result,
            state: state,
            at: start.addingTimeInterval(4),
            claimNonce: "claim-2"
        ) {
            // A fresh extension must not retry a claimed result automatically.
        } else {
            XCTFail("a claimed result must remain fenced")
        }

        let inserted = try! XCTUnwrap(
            InsertionFenceReducer.markInserted(
                claimed,
                resultID: result.resultID,
                sessionID: sessionID,
                dictationID: dictationID,
                claimNonce: "claim-1",
                at: start.addingTimeInterval(5)
            )
        )
        XCTAssertEqual(inserted.status, .inserted)
        XCTAssertNil(
            InsertionFenceReducer.markInserted(
                inserted,
                resultID: result.resultID,
                sessionID: sessionID,
                dictationID: dictationID,
                claimNonce: "claim-1",
                at: start.addingTimeInterval(6)
            )
        )
        let responsiveState = SessionReducer.reduce(
            state,
            .heartbeat(sessionID: sessionID, at: start.addingTimeInterval(7))
        )
        if case .alreadyInserted(_) = InsertionFenceReducer.claim(
            existing: inserted,
            result: result,
            state: responsiveState,
            at: start.addingTimeInterval(7),
            claimNonce: "claim-3"
        ) {
            // Already inserted is also a no-duplicate terminal state.
        } else {
            XCTFail("an inserted result must stay terminal")
        }

        var staleState = state
        staleState.hostHeartbeatAt = start.addingTimeInterval(-6)
        if case .unavailable("host-or-result-not-ready") = InsertionFenceReducer.claim(
            existing: nil,
            result: result,
            state: staleState,
            at: start,
            claimNonce: "claim-stale"
        ) {
            // A dead host cannot authorize insertion.
        } else {
            XCTFail("stale heartbeat must fail closed")
        }
    }

    func testCancelAfterTranscriptionDiscardsUnclaimedResult() {
        var state = completedState()
        state = SessionReducer.reduce(
            state,
            .command(command(.cancel, nonce: "cancel-completed", dictationID: dictationID), at: start.addingTimeInterval(3))
        )
        XCTAssertEqual(state.phase, .ready)
        XCTAssertNil(state.result)
        XCTAssertNil(state.dictationID)
    }

    func testEmptyInputContextIsAmbiguous() {
        XCTAssertTrue(InputContextSnapshot(before: "", after: "", selected: nil).isAmbiguous)
        XCTAssertFalse(InputContextSnapshot(before: "draft", after: "", selected: nil).isAmbiguous)
        XCTAssertFalse(InputContextSnapshot(before: "", after: "", selected: "selection").isAmbiguous)

        let first = InputContextSnapshot(
            documentIdentifier: "editor-1",
            before: "draft",
            after: "tail",
            selected: nil,
            capturedAt: start
        )
        let later = InputContextSnapshot(
            documentIdentifier: "editor-1",
            before: "draft",
            after: "tail",
            selected: nil,
            capturedAt: start.addingTimeInterval(1)
        )
        XCTAssertEqual(first, later)
        XCTAssertNotEqual(first, InputContextSnapshot(documentIdentifier: "editor-1", before: "changed", after: "tail", selected: nil))
        XCTAssertFalse(InputContextSnapshot(documentIdentifier: "editor-1", before: "", after: "", selected: nil).isAmbiguous)
    }
}
