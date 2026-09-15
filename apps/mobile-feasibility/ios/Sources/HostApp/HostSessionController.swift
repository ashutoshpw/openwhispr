import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class HostSessionController: ObservableObject {
    static let sessionLease: TimeInterval = 15 * 60
    static let dictationCap: TimeInterval = 120

    @Published private(set) var state = SessionState()
    @Published private(set) var statusMessage = "Activate OpenWhispr once, then return to the keyboard."
    @Published private(set) var capturedFrames = 0

    private let store = AppGroupStore()
    private let audio = AudioSessionController()
    private let fixtureTranscriber = FixtureTranscriber()
    private var signalObserver: AppGroupSignalObserver?
    private var heartbeatTimer: Timer?
    private var recordingStartedAt: Date?
    private var observers: [NSObjectProtocol] = []

    init() {
        state = SessionReducer.reduce(state, .hostLaunched)
        _ = writeState()

        signalObserver = AppGroupSignalObserver(queue: .main) { [weak self] in
            self?.consumeLatestCommand()
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        })
    }

    deinit {
        heartbeatTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        audio.deactivate()
    }

    var sessionIsActive: Bool {
        state.hasActiveSession && audio.isActive
    }

    func noteActivationRequest() {
        statusMessage = "OpenWhispr is ready to activate the companion-owned recording session."
    }

    func activateSession() {
        guard !sessionIsActive else {
            statusMessage = "The recording session is already active. The microphone remains active until End Session."
            return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.statusMessage = "Microphone permission was denied. Enable it in Settings, then try again."
                    return
                }
                self.finishActivation()
            }
        }
    }

    func endSession() {
        guard let sessionID = state.sessionID else {
            audio.deactivate()
            statusMessage = "No activation session is running."
            return
        }
        let previousResult = state.result
        audio.deactivate()
        recordingStartedAt = nil
        state = SessionReducer.reduce(state, .expire(sessionID: sessionID, at: Date()))
        if let previousResult {
            do {
                _ = try store.cancelInsertion(
                    resultID: previousResult.resultID,
                    sessionID: sessionID,
                    at: Date()
                )
            } catch {
                failClosed(error)
                return
            }
        }
        guard writeState() else { return }
        statusMessage = "Session ended. Return to the keyboard and activate again before recording."
    }

    /// A visible test control makes session-expiry evidence repeatable on a
    /// device. It is intentionally separate from the 120-second dictation cap.
    func expireSessionForTest() {
        endSession()
    }

    private func finishActivation() {
        do {
            try audio.activate()
            let now = Date()
            let sessionID = UUID().uuidString
            state = SessionReducer.reduce(
                state,
                .activate(
                    sessionID: sessionID,
                    expiresAt: now.addingTimeInterval(Self.sessionLease),
                    at: now
                )
            )
            guard writeState() else {
                audio.deactivate()
                return
            }
            statusMessage = "Microphone session active. Samples outside dictation are discarded. Use End Session when finished."
        } catch {
            audio.deactivate()
            statusMessage = "Could not activate the audio session: \(error.localizedDescription)"
        }
    }

    private func heartbeat() {
        guard consumePendingCommands() else { return }
        let now = Date()
        guard let sessionID = state.sessionID, state.hasActiveSession else { return }

        if let expiresAt = state.sessionExpiresAt, expiresAt <= now {
            endSession()
            return
        }

        if state.phase == .recording,
           let startedAt = recordingStartedAt,
           now.timeIntervalSince(startedAt) >= Self.dictationCap {
            finishCurrentDictation(dictationID: state.dictationID, capReached: true)
            return
        }

        state = SessionReducer.reduce(state, .heartbeat(sessionID: sessionID, at: now))
        _ = writeState()
    }

    private func consumeLatestCommand() {
        _ = consumePendingCommands()
    }

    @discardableResult
    private func consumePendingCommands() -> Bool {
        var processed = 0
        while processed < 64 {
            let command: SessionCommand?
            do {
                command = try store.nextCommand()
            } catch {
                failClosed(error)
                return false
            }
            guard let command else { break }

            let now = Date()
            let previous = state
            state = SessionReducer.reduce(state, .command(command, at: now))
            guard writeState() else { return false }

            if previous.phase != .recording, state.phase == .recording {
                recordingStartedAt = now
                audio.beginDictation()
            } else if previous.phase == .recording, state.phase == .transcribing {
                finishCurrentDictation(dictationID: state.dictationID, capReached: false)
                guard state.hasActiveSession else { return false }
            } else if previous.phase == .recording, state.phase == .ready {
                recordingStartedAt = nil
                capturedFrames = audio.endDictation()
                statusMessage = "Dictation cancelled. The activation session remains ready."
            }

            if command.kind == .cancel,
               previous.phase == .completed,
               let result = previous.result,
               let sessionID = previous.sessionID {
                do {
                    _ = try store.cancelInsertion(
                        resultID: result.resultID,
                        sessionID: sessionID,
                        at: now
                    )
                } catch {
                    failClosed(error)
                    return false
                }
            }

            if command.kind == .acknowledgeResult,
               previous.phase == .completed,
               state.phase == .ready,
               let result = previous.result,
               let sessionID = previous.sessionID,
               let claimNonce = command.insertionFenceNonce {
                do {
                    _ = try store.markInsertionInserted(
                        resultID: result.resultID,
                        sessionID: sessionID,
                        dictationID: result.dictationID,
                        claimNonce: claimNonce,
                        at: now
                    )
                } catch {
                    failClosed(error)
                    return false
                }
            }

            do {
                _ = try store.acknowledgeCommand(nonce: command.nonce)
            } catch {
                failClosed(error)
                return false
            }
            processed += 1
        }
        return true
    }

    private func finishCurrentDictation(dictationID: String?, capReached: Bool) {
        guard let dictationID else { return }
        if capReached {
            state = SessionReducer.reduce(
                state,
                .capReached(dictationID: dictationID, at: Date())
            )
            guard writeState() else { return }
        }

        recordingStartedAt = nil
        capturedFrames = audio.endDictation()
        let transcript = fixtureTranscriber.transcribe(
            capturedFrames: capturedFrames,
            capReached: capReached
        )
        state = SessionReducer.reduce(
            state,
            .finish(
                dictationID: dictationID,
                transcript: transcript,
                capReached: capReached,
                at: Date()
            )
        )
        if let result = state.result, let sessionID = state.sessionID {
            do {
                try store.prepareInsertionFence(
                    for: result,
                    sessionID: sessionID,
                    at: Date()
                )
            } catch {
                failClosed(error)
                return
            }
        }
        guard writeState() else { return }
        statusMessage = capReached
            ? "The 120-second dictation cap ended this dictation. The activation session is still available."
            : "Fixture transcription is ready in the keyboard."
    }

    private func handleInterruption(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value)
        else { return }

        switch type {
        case .began:
            statusMessage = "Audio interrupted. The host will try to recover the active session."
        case .ended:
            do {
                try audio.resumeAfterInterruption()
                statusMessage = "Audio interruption recovered; the activation session remains available."
            } catch {
                statusMessage = "Audio could not recover. Reactivate the session before recording again."
                endSession()
            }
        @unknown default:
            statusMessage = "Unknown audio interruption. Reactivate if recording cannot resume."
        }
    }

    @discardableResult
    private func writeState() -> Bool {
        do {
            try store.writeState(state)
        } catch {
            failClosed(error)
            return false
        }
        AppGroupSignalObserver.post()
        return true
    }

    private func failClosed(_ error: Error) {
        audio.deactivate()
        recordingStartedAt = nil
        state = SessionState()
        statusMessage = "Protocol storage unavailable; audio stopped. Reactivate OpenWhispr. \(error.localizedDescription)"
    }
}
