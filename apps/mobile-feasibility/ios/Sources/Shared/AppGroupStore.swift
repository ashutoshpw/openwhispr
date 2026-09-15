#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum AppGroupConstants {
    public static let identifier = "group.com.openwhispr.ios.feasibility"
    public static let stateKey = "ios-feasibility.state.v1"
    public static let commandQueueKey = "ios-feasibility.command-queue.v1"
    public static let insertionFencesKey = "ios-feasibility.insertion-fences.v1"
    public static let signalName = "com.openwhispr.ios.feasibility.command.v1"

    public static let protocolLockFileName = "ios-feasibility.protocol.lock"
    public static let commandQueueFileName = "ios-feasibility.command-queue.v1.json"
    public static let insertionFencesFileName = "ios-feasibility.insertion-fences.v1.json"
}

public enum AppGroupStoreError: Error, Equatable, LocalizedError, Sendable {
    case lockOpenFailed(Int32)
    case lockAcquireFailed(Int32)
    case stateEncodingFailed(String)
    case stateDecodingFailed(String)
    case stateSynchronizeFailed
    case commandReadFailed(String)
    case commandDecodeFailed(String)
    case commandEncodeFailed(String)
    case commandWriteFailed(String)
    case fenceReadFailed(String)
    case fenceDecodeFailed(String)
    case fenceEncodeFailed(String)
    case fenceWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .lockOpenFailed(code):
            return "Could not open the App Group protocol lock (errno \(code))."
        case let .lockAcquireFailed(code):
            return "Could not acquire the App Group protocol lock (errno \(code))."
        case let .stateEncodingFailed(detail):
            return "Could not encode App Group session state: \(detail)"
        case let .stateDecodingFailed(detail):
            return "Could not decode App Group session state: \(detail)"
        case .stateSynchronizeFailed:
            return "Could not flush App Group session state."
        case let .commandReadFailed(detail):
            return "Could not read the App Group command queue: \(detail)"
        case let .commandDecodeFailed(detail):
            return "Could not decode the App Group command queue: \(detail)"
        case let .commandEncodeFailed(detail):
            return "Could not encode the App Group command queue: \(detail)"
        case let .commandWriteFailed(detail):
            return "Could not atomically write the App Group command queue: \(detail)"
        case let .fenceReadFailed(detail):
            return "Could not read the App Group insertion fences: \(detail)"
        case let .fenceDecodeFailed(detail):
            return "Could not decode the App Group insertion fences: \(detail)"
        case let .fenceEncodeFailed(detail):
            return "Could not encode the App Group insertion fences: \(detail)"
        case let .fenceWriteFailed(detail):
            return "Could not atomically write the App Group insertion fences: \(detail)"
        }
    }
}

/// App Group persistence is intentionally small and typed. Session state stays
/// in UserDefaults, while commands and insertion fences use a file transaction:
/// every mutation rereads under a cross-process flock and replaces its JSON file
/// atomically. An error is thrown instead of being converted to an empty queue,
/// because an empty queue or missing fence would fail open.
public final class AppGroupStore: @unchecked Sendable {
    private static let processLock = NSLock()

    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private let protocolLockURL: URL
    private let commandQueueURL: URL
    private let insertionFencesURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `fileDirectoryURL` is injectable for Foundation tests. Native targets
    /// must use the signed App Group container and fail during initialization if
    /// that entitlement is absent. `lockURL` remains injectable for callers that
    /// need to control the lock path; it must point into the same directory.
    public init(
        defaults: UserDefaults? = nil,
        fileDirectoryURL: URL? = nil,
        lockURL: URL? = nil
    ) {
        guard let defaults = defaults ?? UserDefaults(suiteName: AppGroupConstants.identifier) else {
            fatalError("The iOS feasibility targets require the App Group entitlement.")
        }
        guard let directoryURL = fileDirectoryURL
            ?? lockURL?.deletingLastPathComponent()
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConstants.identifier)
        else {
            fatalError("The iOS feasibility targets require the App Group container entitlement.")
        }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            fatalError("Could not create the App Group protocol directory: \(error.localizedDescription)")
        }

        self.defaults = defaults
        self.protocolLockURL = lockURL
            ?? directoryURL.appendingPathComponent(AppGroupConstants.protocolLockFileName)
        self.commandQueueURL = directoryURL.appendingPathComponent(AppGroupConstants.commandQueueFileName)
        self.insertionFencesURL = directoryURL.appendingPathComponent(AppGroupConstants.insertionFencesFileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func readState() throws -> SessionState {
        try withProtocolLock {
            try synchronizeDefaults()
            guard let data = defaults.data(forKey: AppGroupConstants.stateKey) else {
                return SessionState()
            }
            do {
                return try decoder.decode(SessionState.self, from: data)
            } catch {
                throw AppGroupStoreError.stateDecodingFailed(String(describing: error))
            }
        }
    }

    public func writeState(_ state: SessionState) throws {
        try withProtocolLock {
            let data: Data
            do {
                data = try encoder.encode(state)
            } catch {
                throw AppGroupStoreError.stateEncodingFailed(String(describing: error))
            }
            defaults.set(data, forKey: AppGroupConstants.stateKey)
            try synchronizeDefaults()
        }
    }

    public func enqueueCommand(_ command: SessionCommand) throws {
        try withProtocolLock {
            var queue = SessionCommandQueue(commands: try readCommandQueueWithoutLock())
            queue.enqueue(command)
            try writeCommandQueueWithoutLock(queue.commands)
        }
    }

    public func nextCommand() throws -> SessionCommand? {
        try withProtocolLock {
            try readCommandQueueWithoutLock().first
        }
    }

    @discardableResult
    public func acknowledgeCommand(nonce: String) throws -> Bool {
        try withProtocolLock {
            var queue = SessionCommandQueue(commands: try readCommandQueueWithoutLock())
            guard queue.acknowledge(nonce: nonce) else {
                return false
            }
            try writeCommandQueueWithoutLock(queue.commands)
            return true
        }
    }

    public func prepareInsertionFence(
        for result: TranscriptResult,
        sessionID: String,
        at now: Date
    ) throws {
        try withProtocolLock {
            var fences = try readInsertionFencesWithoutLock()
            guard fences[result.resultID] == nil else { return }
            fences[result.resultID] = InsertionFence(
                resultID: result.resultID,
                sessionID: sessionID,
                dictationID: result.dictationID,
                status: .available,
                updatedAt: now
            )
            try writeInsertionFencesWithoutLock(fences)
        }
    }

    public func claimInsertion(
        for result: TranscriptResult,
        state: SessionState,
        at now: Date
    ) throws -> InsertionClaimResult {
        guard state.hostIsResponsive(at: now) else {
            return .unavailable("host-heartbeat-stale")
        }

        return try withProtocolLock {
            var fences = try readInsertionFencesWithoutLock()
            let outcome = InsertionFenceReducer.claim(
                existing: fences[result.resultID],
                result: result,
                state: state,
                at: now,
                claimNonce: UUID().uuidString
            )
            if case let .claimed(fence) = outcome {
                // If this write fails, no claim is returned to the keyboard and
                // insertText must not be called.
                fences[result.resultID] = fence
                try writeInsertionFencesWithoutLock(fences)
            }
            return outcome
        }
    }

    @discardableResult
    public func markInsertionInserted(
        resultID: String,
        sessionID: String,
        dictationID: String,
        claimNonce: String,
        at now: Date
    ) throws -> Bool {
        try withProtocolLock {
            var fences = try readInsertionFencesWithoutLock()
            guard let fence = fences[resultID],
                  let inserted = InsertionFenceReducer.markInserted(
                      fence,
                      resultID: resultID,
                      sessionID: sessionID,
                      dictationID: dictationID,
                      claimNonce: claimNonce,
                      at: now
                  )
            else {
                return false
            }
            fences[resultID] = inserted
            try writeInsertionFencesWithoutLock(fences)
            return true
        }
    }

    @discardableResult
    public func cancelInsertion(
        resultID: String,
        sessionID: String,
        at now: Date
    ) throws -> Bool {
        try withProtocolLock {
            var fences = try readInsertionFencesWithoutLock()
            guard let fence = fences[resultID], fence.sessionID == sessionID,
                  let cancelled = InsertionFenceReducer.cancel(fence, at: now)
            else {
                return false
            }
            fences[resultID] = cancelled
            try writeInsertionFencesWithoutLock(fences)
            return true
        }
    }

    private func withProtocolLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        let descriptor = protocolLockURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw AppGroupStoreError.lockOpenFailed(errno)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw AppGroupStoreError.lockAcquireFailed(code)
        }

        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        return try body()
    }

    private func synchronizeDefaults() throws {
        guard defaults.synchronize() else {
            throw AppGroupStoreError.stateSynchronizeFailed
        }
    }

    private func readCommandQueueWithoutLock() throws -> [SessionCommand] {
        guard let data = try readDataIfPresent(at: commandQueueURL, kind: .command) else {
            return []
        }
        do {
            return try decoder.decode([SessionCommand].self, from: data)
        } catch {
            throw AppGroupStoreError.commandDecodeFailed(String(describing: error))
        }
    }

    private func writeCommandQueueWithoutLock(_ commands: [SessionCommand]) throws {
        let data: Data
        do {
            data = try encoder.encode(commands)
        } catch {
            throw AppGroupStoreError.commandEncodeFailed(String(describing: error))
        }
        try writeAtomically(data, to: commandQueueURL, kind: .command)
    }

    private func readInsertionFencesWithoutLock() throws -> [String: InsertionFence] {
        guard let data = try readDataIfPresent(at: insertionFencesURL, kind: .fence) else {
            return [:]
        }
        do {
            return try decoder.decode([String: InsertionFence].self, from: data)
        } catch {
            throw AppGroupStoreError.fenceDecodeFailed(String(describing: error))
        }
    }

    private func writeInsertionFencesWithoutLock(_ fences: [String: InsertionFence]) throws {
        let data: Data
        do {
            data = try encoder.encode(fences)
        } catch {
            throw AppGroupStoreError.fenceEncodeFailed(String(describing: error))
        }
        try writeAtomically(data, to: insertionFencesURL, kind: .fence)
    }

    private enum FileKind {
        case command
        case fence
    }

    private func readDataIfPresent(at url: URL, kind: FileKind) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            let detail = String(describing: error)
            switch kind {
            case .command:
                throw AppGroupStoreError.commandReadFailed(detail)
            case .fence:
                throw AppGroupStoreError.fenceReadFailed(detail)
            }
        }
    }

    private func writeAtomically(_ data: Data, to url: URL, kind: FileKind) throws {
        do {
            // Foundation writes to a same-directory temporary file and renames
            // it into place for `.atomic`; the flock makes the whole
            // read-modify-write transaction mutually exclusive across targets.
            try data.write(to: url, options: [.atomic])
        } catch {
            let detail = String(describing: error)
            switch kind {
            case .command:
                throw AppGroupStoreError.commandWriteFailed(detail)
            case .fence:
                throw AppGroupStoreError.fenceWriteFailed(detail)
            }
        }
    }
}
