import Foundation
import UIKit

/// A deliberately small but usable keyboard for the feasibility prototype. The
/// microphone control is an IPC client; this target has no AVFoundation import,
/// microphone permission, or recording implementation.
final class KeyboardViewController: UIInputViewController {
    private let store = AppGroupStore()
    private var signalObserver: AppGroupSignalObserver?
    private var refreshTimer: Timer?
    private var state = SessionState()
    private var targetSnapshot: InputContextSnapshot?
    private var lastInsertedResultID: String?
    private var isApplyingInsertion = false
    private var cancellationSentForDictationID: String?
    private var blockedFence: InsertionFence?
    private var manualRecoveryCopied = false

    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        buildKeyboard()

        signalObserver = AppGroupSignalObserver(queue: .main) { [weak self] in
            self?.refreshFromStore()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshFromStore()
        }
        refreshFromStore()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshFromStore()
    }

    override func viewWillDisappear(_ animated: Bool) {
        if !isApplyingInsertion, state.phase == .recording {
            cancelCurrentDictation(reason: "Keyboard closed; dictation cancelled.")
        }
        super.viewWillDisappear(animated)
    }

    override func textWillChange(_ textInput: UITextInput?) {
        if !isApplyingInsertion, state.phase == .recording {
            cancelCurrentDictation(reason: "Editor changed; dictation cancelled to protect the original target.")
        }
        super.textWillChange(textInput)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        if !isApplyingInsertion, state.phase == .recording {
            cancelCurrentDictation(reason: "Editor changed; dictation cancelled to protect the original target.")
        }
        super.textDidChange(textInput)
        refreshFromStore()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func buildKeyboard() {
        view.backgroundColor = .secondarySystemBackground

        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])

        let top = UIStackView()
        top.axis = .horizontal
        top.spacing = 6
        top.alignment = .fill

        let nextKeyboard = makeButton(title: "🌐", action: #selector(nextKeyboardTapped))
        nextKeyboard.accessibilityLabel = "Next keyboard"
        nextKeyboard.widthAnchor.constraint(equalToConstant: 44).isActive = true

        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel
        top.addArrangedSubview(nextKeyboard)
        top.addArrangedSubview(statusLabel)

        micButton.setTitle("🎙", for: .normal)
        micButton.titleLabel?.font = .systemFont(ofSize: 22)
        micButton.accessibilityLabel = "OpenWhispr microphone"
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        top.addArrangedSubview(micButton)
        root.addArrangedSubview(top)

        retryButton.setTitle("Insert fixture result", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        retryButton.addTarget(self, action: #selector(retryInsertion), for: .touchUpInside)
        retryButton.isHidden = true
        root.addArrangedSubview(retryButton)

        ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"].forEach { letters in
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 4
            row.distribution = .fillEqually
            for letter in letters {
                let button = makeButton(title: String(letter), action: #selector(letterTapped(_:)))
                button.accessibilityLabel = String(letter).lowercased()
                row.addArrangedSubview(button)
            }
            root.addArrangedSubview(row)
        }

        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 4
        bottom.distribution = .fill
        let space = makeButton(title: "space", action: #selector(spaceTapped))
        space.accessibilityLabel = "Space"
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let backspace = makeButton(title: "⌫", action: #selector(backspaceTapped))
        backspace.accessibilityLabel = "Backspace"
        backspace.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let enter = makeButton(title: "return", action: #selector(returnTapped))
        enter.accessibilityLabel = "Return"
        enter.widthAnchor.constraint(equalToConstant: 62).isActive = true
        bottom.addArrangedSubview(space)
        bottom.addArrangedSubview(enter)
        bottom.addArrangedSubview(backspace)
        root.addArrangedSubview(bottom)
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.backgroundColor = .systemBackground
        button.layer.cornerRadius = 6
        button.addTarget(self, action: action, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return button
    }

    private func refreshFromStore() {
        let nextState: SessionState
        do {
            nextState = try store.readState()
        } catch {
            state = SessionState()
            statusLabel.text = "Shared state unavailable; reactivate OpenWhispr.\n\(error.localizedDescription)"
            micButton.isEnabled = false
            retryButton.isHidden = true
            return
        }
        let changedResult = nextState.result?.resultID != lastInsertedResultID
        state = nextState

        switch state.phase {
        case .inactive, .expired:
            statusLabel.text = "Activate in OpenWhispr"
            micButton.setTitle("🎙", for: .normal)
            micButton.isEnabled = true
            retryButton.isHidden = true
        case .ready:
            statusLabel.text = state.hostIsResponsive(at: Date()) ? "Ready" : "Host needs activation"
            micButton.setTitle("🎙", for: .normal)
            // Keep the control usable so a stale lease can open the containing
            // app for explicit reactivation.
            micButton.isEnabled = true
            retryButton.isHidden = true
        case .recording:
            statusLabel.text = "Recording… tap 🎙 to stop"
            micButton.setTitle("■", for: .normal)
            micButton.isEnabled = true
            retryButton.isHidden = true
        case .transcribing:
            statusLabel.text = "Preparing fixture result…"
            micButton.isEnabled = false
            retryButton.isHidden = true
        case .completed:
            statusLabel.text = state.result?.label ?? "Result ready"
            micButton.setTitle("Insert", for: .normal)
            micButton.isEnabled = true
            retryButton.isHidden = false
            if blockedFence?.resultID != state.result?.resultID {
                blockedFence = nil
                manualRecoveryCopied = false
            }
            retryButton.setTitle(
                blockedFence == nil
                    ? "Insert fixture result"
                    : (manualRecoveryCopied ? "Acknowledge manual insertion" : "Copy fixture result"),
                for: .normal
            )
            if changedResult, targetSnapshot != nil, blockedFence == nil {
                attemptInsertion(explicitRetry: false)
            }
        }

        if let error = state.lastError, !error.isEmpty {
            statusLabel.text = "\(statusLabel.text ?? "")\n\(error)"
        }
    }

    @objc private func micTapped() {
        refreshFromStore()
        let now = Date()

        switch state.phase {
        case .inactive, .expired:
            openContainingApp()
        case .ready:
            guard state.hostIsResponsive(at: now), let sessionID = state.sessionID else {
                statusLabel.text = "Host is not responding; activate again."
                openContainingApp()
                return
            }
            guard let context = captureContext(), !context.isAmbiguous else {
                statusLabel.text = "Place the cursor in an identifiable editable field first."
                return
            }
            let dictationID = UUID().uuidString
            targetSnapshot = context
            cancellationSentForDictationID = nil
            guard send(SessionCommand(
                kind: .start,
                nonce: UUID().uuidString,
                sessionID: sessionID,
                dictationID: dictationID,
                issuedAt: now
            )) else {
                targetSnapshot = nil
                cancellationSentForDictationID = nil
                return
            }
        case .recording:
            guard let sessionID = state.sessionID, let dictationID = state.dictationID else { return }
            send(SessionCommand(
                kind: .stop,
                nonce: UUID().uuidString,
                sessionID: sessionID,
                dictationID: dictationID,
                issuedAt: now
            ))
        case .completed:
            attemptInsertion(explicitRetry: true)
        case .transcribing:
            break
        }
    }

    @objc private func retryInsertion() {
        if blockedFence != nil {
            if manualRecoveryCopied {
                acknowledgeBlockedResult()
            } else {
                copyResultForManualRecovery()
            }
            return
        }
        attemptInsertion(explicitRetry: true)
    }

    private func attemptInsertion(explicitRetry: Bool) {
        guard state.phase == .completed,
              let result = state.result,
              result.resultID != lastInsertedResultID
        else { return }

        guard state.hostIsResponsive(at: Date()) else {
            statusLabel.text = "Host is unavailable; reactivate before inserting this result."
            retryButton.isHidden = false
            return
        }

        guard let current = captureContext(), !current.isAmbiguous else {
            statusLabel.text = "Target is ambiguous; place the cursor and tap Insert fixture result."
            retryButton.isHidden = false
            return
        }

        if let targetSnapshot, targetSnapshot != current {
            guard explicitRetry else {
                statusLabel.text = "Target changed; tap Insert fixture result to confirm the new target."
                retryButton.isHidden = false
                return
            }
        }

        let claim: InsertionFence
        let claimResult: InsertionClaimResult
        do {
            claimResult = try store.claimInsertion(for: result, state: state, at: Date())
        } catch {
            statusLabel.text = "Insertion unavailable; automatic insertion is disabled.\n\(error.localizedDescription)"
            retryButton.isHidden = false
            return
        }
        switch claimResult {
        case let .claimed(fence):
            claim = fence
        case let .alreadyClaimed(fence):
            blockedFence = fence
            manualRecoveryCopied = false
            retryButton.setTitle("Copy fixture result", for: .normal)
            statusLabel.text = "Insertion is ambiguous after a prior attempt; copy and recover manually. Automatic retry is disabled."
            return
        case let .alreadyInserted(fence):
            blockedFence = fence
            manualRecoveryCopied = true
            retryButton.setTitle("Acknowledge existing insertion", for: .normal)
            statusLabel.text = "This result is already fenced as inserted; no duplicate was attempted."
            return
        case let .unavailable(reason):
            statusLabel.text = "Insertion unavailable: \(reason)"
            retryButton.isHidden = false
            return
        }

        targetSnapshot = current
        isApplyingInsertion = true
        textDocumentProxy.insertText(result.text)
        isApplyingInsertion = false
        guard let sessionID = state.sessionID,
              let claimNonce = claim.claimNonce else {
            blockedFence = claim
            manualRecoveryCopied = false
            retryButton.setTitle("Copy fixture result", for: .normal)
            statusLabel.text = "Insertion was attempted but its durable fence could not be finalized. Automatic retry is disabled."
            return
        }
        do {
            guard try store.markInsertionInserted(
                resultID: result.resultID,
                sessionID: sessionID,
                dictationID: result.dictationID,
                claimNonce: claimNonce,
                at: Date()
            ) else {
                blockedFence = claim
                manualRecoveryCopied = false
                retryButton.setTitle("Copy fixture result", for: .normal)
                statusLabel.text = "Insertion was attempted but its durable fence could not be finalized. Automatic retry is disabled."
                return
            }
        } catch {
            blockedFence = claim
            manualRecoveryCopied = false
            retryButton.setTitle("Copy fixture result", for: .normal)
            statusLabel.text = "Insertion was attempted but its durable fence could not be finalized. Automatic retry is disabled.\n\(error.localizedDescription)"
            return
        }
        lastInsertedResultID = result.resultID
        retryButton.isHidden = true

        if !send(SessionCommand(
            kind: .acknowledgeResult,
            nonce: UUID().uuidString,
            sessionID: sessionID,
            dictationID: result.dictationID,
            resultID: result.resultID,
            insertionFenceNonce: claimNonce,
            issuedAt: Date()
        )) {
            blockedFence = claim
            manualRecoveryCopied = true
            retryButton.isHidden = false
            retryButton.setTitle("Acknowledge existing insertion", for: .normal)
            statusLabel.text = "Text was inserted and durably fenced, but acknowledgement is pending. Tap to retry."
        }
    }

    private func copyResultForManualRecovery() {
        guard let result = state.result, blockedFence != nil else { return }
        UIPasteboard.general.string = result.text
        manualRecoveryCopied = true
        retryButton.setTitle("Acknowledge manual insertion", for: .normal)
        statusLabel.text = "Fixture result copied. Paste it only after verifying the original insertion did not occur, then acknowledge."
    }

    private func acknowledgeBlockedResult() {
        guard let result = state.result,
              let fence = blockedFence,
              let sessionID = state.sessionID,
              state.hostIsResponsive(at: Date()),
              let claimNonce = fence.claimNonce
        else {
            statusLabel.text = "Host is unavailable; reactivate before acknowledging recovery."
            return
        }
        guard send(SessionCommand(
            kind: .acknowledgeResult,
            nonce: UUID().uuidString,
            sessionID: sessionID,
            dictationID: result.dictationID,
            resultID: result.resultID,
            insertionFenceNonce: claimNonce,
            issuedAt: Date()
        )) else { return }
        blockedFence = nil
        manualRecoveryCopied = false
    }

    private func cancelCurrentDictation(reason: String) {
        guard state.phase == .recording,
              let sessionID = state.sessionID,
              let dictationID = state.dictationID,
              cancellationSentForDictationID != dictationID
        else { return }
        guard send(SessionCommand(
            kind: .cancel,
            nonce: UUID().uuidString,
            sessionID: sessionID,
            dictationID: dictationID,
            issuedAt: Date()
        )) else { return }
        cancellationSentForDictationID = dictationID
        targetSnapshot = nil
        statusLabel.text = reason
    }

    @discardableResult
    private func send(_ command: SessionCommand) -> Bool {
        do {
            try store.enqueueCommand(command)
        } catch {
            statusLabel.text = "The shared command store is unavailable; reactivate the host and try again.\n\(error.localizedDescription)"
            return false
        }
        AppGroupSignalObserver.post()
        refreshFromStore()
        return true
    }

    private func captureContext() -> InputContextSnapshot? {
        let proxy = textDocumentProxy
        return InputContextSnapshot(
            documentIdentifier: proxy.documentIdentifier.uuidString,
            before: proxy.documentContextBeforeInput ?? "",
            after: proxy.documentContextAfterInput ?? "",
            selected: proxy.selectedText
        )
    }

    private func openContainingApp() {
        guard let url = URL(string: "openwhispr-feasibility://activate") else { return }
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                self?.statusLabel.text = success
                    ? "Activate in OpenWhispr, then return here."
                    : "Open OpenWhispr once to activate this session."
            }
        }
    }

    @objc private func nextKeyboardTapped() {
        advanceToNextInputMode()
    }

    @objc private func letterTapped(_ sender: UIButton) {
        guard let title = sender.currentTitle else { return }
        textDocumentProxy.insertText(title.lowercased())
    }

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func backspaceTapped() {
        textDocumentProxy.deleteBackward()
    }
}
