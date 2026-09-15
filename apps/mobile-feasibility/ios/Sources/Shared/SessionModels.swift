import Foundation

/// The lifecycle of the companion-owned microphone session and its current dictation.
public enum SessionPhase: String, Codable, Equatable, Sendable {
    case inactive
    case ready
    case recording
    case transcribing
    case completed
    case expired
}

public enum SessionCommandKind: String, Codable, Equatable, Sendable {
    case start
    case stop
    case cancel
    case acknowledgeResult
}

/// The result is deliberately tagged so that fixture output cannot be mistaken for
/// a provider-backed transcription during feasibility review.
public struct TranscriptResult: Codable, Equatable, Sendable {
    public let resultID: String
    public let dictationID: String
    public let text: String
    public let label: String
    public let capReached: Bool

    public init(
        resultID: String,
        dictationID: String,
        text: String,
        label: String,
        capReached: Bool
    ) {
        self.resultID = resultID
        self.dictationID = dictationID
        self.text = text
        self.label = label
        self.capReached = capReached
    }
}

/// A versioned command is written to the App Group before the Darwin notification
/// is posted. The notification is only a wake-up signal; consumers always reread
/// and validate this complete payload.
public struct SessionCommand: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let kind: SessionCommandKind
    public let nonce: String
    public let sessionID: String
    public let dictationID: String?
    public let resultID: String?
    public let insertionFenceNonce: String?
    public let issuedAt: Date

    public init(
        kind: SessionCommandKind,
        nonce: String,
        sessionID: String,
        dictationID: String? = nil,
        resultID: String? = nil,
        insertionFenceNonce: String? = nil,
        issuedAt: Date = Date(),
        schemaVersion: Int = SessionCommand.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.nonce = nonce
        self.sessionID = sessionID
        self.dictationID = dictationID
        self.resultID = resultID
        self.insertionFenceNonce = insertionFenceNonce
        self.issuedAt = issuedAt
    }
}

public struct SessionCommandQueue: Equatable, Sendable {
    public private(set) var commands: [SessionCommand]

    public init(commands: [SessionCommand] = []) {
        self.commands = commands
    }

    public var next: SessionCommand? {
        commands.first
    }

    public mutating func enqueue(_ command: SessionCommand) {
        guard !commands.contains(where: { $0.nonce == command.nonce }) else { return }
        commands.append(command)
    }

    @discardableResult
    public mutating func acknowledge(nonce: String) -> Bool {
        guard let index = commands.firstIndex(where: { $0.nonce == nonce }) else { return false }
        commands.remove(at: index)
        return true
    }
}

public struct SessionState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var phase: SessionPhase
    public var sessionID: String?
    public var dictationID: String?
    public var activeCommandNonce: String?
    public var appliedCommandNonces: [String]
    public var result: TranscriptResult?
    public var hostHeartbeatAt: Date?
    public var sessionExpiresAt: Date?
    public var lastError: String?

    public init(
        schemaVersion: Int = SessionState.currentSchemaVersion,
        phase: SessionPhase = .inactive,
        sessionID: String? = nil,
        dictationID: String? = nil,
        activeCommandNonce: String? = nil,
        appliedCommandNonces: [String] = [],
        result: TranscriptResult? = nil,
        hostHeartbeatAt: Date? = nil,
        sessionExpiresAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.sessionID = sessionID
        self.dictationID = dictationID
        self.activeCommandNonce = activeCommandNonce
        self.appliedCommandNonces = appliedCommandNonces
        self.result = result
        self.hostHeartbeatAt = hostHeartbeatAt
        self.sessionExpiresAt = sessionExpiresAt
        self.lastError = lastError
    }

    public var hasActiveSession: Bool {
        switch phase {
        case .ready, .recording, .transcribing, .completed:
            return sessionID != nil
        case .inactive, .expired:
            return false
        }
    }

    /// This is a liveness check, not a promise that Darwin notifications can wake
    /// a suspended host process. The keyboard must fail closed when the host has
    /// stopped refreshing its heartbeat.
    public func hostIsResponsive(at now: Date, heartbeatGrace: TimeInterval = 5) -> Bool {
        guard hasActiveSession,
              let heartbeat = hostHeartbeatAt,
              let expiresAt = sessionExpiresAt,
              expiresAt > now,
              now.timeIntervalSince(heartbeat) <= heartbeatGrace,
              heartbeat.timeIntervalSince(now) <= heartbeatGrace
        else {
            return false
        }
        return true
    }
}

public enum SessionAction: Equatable, Sendable {
    case hostLaunched
    case activate(sessionID: String, expiresAt: Date, at: Date)
    case heartbeat(sessionID: String, at: Date)
    case command(SessionCommand, at: Date)
    case capReached(dictationID: String, at: Date)
    case finish(dictationID: String, transcript: String, capReached: Bool, at: Date)
    case expire(sessionID: String, at: Date)
}

public struct InputContextSnapshot: Codable, Equatable, Sendable {
    public let documentIdentifier: String?
    public let before: String
    public let after: String
    public let selected: String?
    public let capturedAt: Date

    public init(
        documentIdentifier: String? = nil,
        before: String,
        after: String,
        selected: String?,
        capturedAt: Date = Date()
    ) {
        self.documentIdentifier = documentIdentifier
        self.before = before
        self.after = after
        self.selected = selected
        self.capturedAt = capturedAt
    }

    /// An empty context gives the extension no evidence that the target stayed
    /// editable. The prototype refuses to insert into that ambiguous target.
    public var isAmbiguous: Bool {
        documentIdentifier == nil && before.isEmpty && after.isEmpty && (selected ?? "").isEmpty
    }

    /// Capture time documents when the target was sampled but is not part of
    /// target identity. Comparing it would make every unchanged editor look
    /// different when the result arrives.
    public static func == (lhs: InputContextSnapshot, rhs: InputContextSnapshot) -> Bool {
        lhs.documentIdentifier == rhs.documentIdentifier &&
            lhs.before == rhs.before &&
            lhs.after == rhs.after &&
            lhs.selected == rhs.selected
    }
}

public enum InsertionFenceStatus: String, Codable, Equatable, Sendable {
    case available
    case claimed
    case inserted
    case cancelled
}

public struct InsertionFence: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let resultID: String
    public let sessionID: String
    public let dictationID: String
    public var status: InsertionFenceStatus
    public var claimNonce: String?
    public var updatedAt: Date

    public init(
        resultID: String,
        sessionID: String,
        dictationID: String,
        status: InsertionFenceStatus,
        claimNonce: String? = nil,
        updatedAt: Date,
        schemaVersion: Int = InsertionFence.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.resultID = resultID
        self.sessionID = sessionID
        self.dictationID = dictationID
        self.status = status
        self.claimNonce = claimNonce
        self.updatedAt = updatedAt
    }
}

public enum InsertionClaimResult: Equatable, Sendable {
    case claimed(InsertionFence)
    case alreadyClaimed(InsertionFence)
    case alreadyInserted(InsertionFence)
    case unavailable(String)
}
