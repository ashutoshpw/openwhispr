import Dispatch
import Foundation
import XCTest
@testable import OpenWhisprIOSFeasibilityCore

final class AppGroupStoreTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwhispr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStores() throws -> (URL, AppGroupStore, AppGroupStore) {
        let directory = try makeDirectory()
        let suiteName = "openwhispr.ios.feasibility.tests.\(UUID().uuidString)"
        guard let defaultsA = UserDefaults(suiteName: suiteName),
              let defaultsB = UserDefaults(suiteName: suiteName)
        else {
            throw NSError(domain: "AppGroupStoreTests", code: 1)
        }
        let storeA = AppGroupStore(defaults: defaultsA, fileDirectoryURL: directory)
        let storeB = AppGroupStore(defaults: defaultsB, fileDirectoryURL: directory)
        return (directory, storeA, storeB)
    }

    func testIndependentStoresPreserveCommandsDuringConcurrentReadModifyWrite() throws {
        let (directory, storeA, storeB) = try makeStores()
        defer { try? FileManager.default.removeItem(at: directory) }

        let commands = (0..<16).map { index in
            SessionCommand(
                kind: .start,
                nonce: "command-\(index)",
                sessionID: "session-1",
                dictationID: "dictation-\(index)"
            )
        }
        let queue = DispatchQueue(label: "app-group-store-command-writers", attributes: .concurrent)
        let group = DispatchGroup()
        let outcomesLock = NSLock()
        var failures = [String]()

        for (index, command) in commands.enumerated() {
            group.enter()
            queue.async {
                let store = index.isMultiple(of: 2) ? storeA : storeB
                do {
                    try store.enqueueCommand(command)
                } catch {
                    outcomesLock.lock()
                    failures.append(String(describing: error))
                    outcomesLock.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        var observedNonces = Set<String>()
        while true {
            let command: SessionCommand?
            do {
                command = try storeA.nextCommand()
            } catch {
                XCTFail("reading the command queue failed: \(error)")
                return
            }
            guard let command else { break }
            observedNonces.insert(command.nonce)
            let acknowledged = try storeB.acknowledgeCommand(nonce: command.nonce)
            XCTAssertTrue(acknowledged)
        }
        XCTAssertEqual(observedNonces, Set(commands.map(\.nonce)))
        let remainingCommand = try storeB.nextCommand()
        XCTAssertNil(remainingCommand)
    }

    func testClaimPersistsAcrossIndependentStoreInstancesAndIsAtMostOnce() throws {
        let (directory, storeA, storeB) = try makeStores()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date()
        let result = TranscriptResult(
            resultID: "result-1",
            dictationID: "dictation-1",
            text: "[Fixture transcription] hello",
            label: "Fixture transcription",
            capReached: false
        )
        let state = SessionState(
            phase: .completed,
            sessionID: "session-1",
            dictationID: result.dictationID,
            result: result,
            hostHeartbeatAt: now,
            sessionExpiresAt: now.addingTimeInterval(60)
        )
        try storeA.prepareInsertionFence(for: result, sessionID: "session-1", at: now)

        let queue = DispatchQueue(label: "app-group-store-claimers", attributes: .concurrent)
        let group = DispatchGroup()
        let outcomesLock = NSLock()
        var outcomes = [Result<InsertionClaimResult, Error>]()
        for store in [storeA, storeB] {
            group.enter()
            queue.async {
                do {
                    let outcome = try store.claimInsertion(for: result, state: state, at: now)
                    outcomesLock.lock()
                    outcomes.append(.success(outcome))
                    outcomesLock.unlock()
                } catch {
                    outcomesLock.lock()
                    outcomes.append(.failure(error))
                    outcomesLock.unlock()
                }
                group.leave()
            }
        }
        group.wait()

        let successfulOutcomes = outcomes.compactMap { try? $0.get() }
        XCTAssertEqual(successfulOutcomes.count, 2)
        let claimed = successfulOutcomes.compactMap { outcome -> InsertionFence? in
            guard case let .claimed(fence) = outcome else { return nil }
            return fence
        }
        let alreadyClaimed = successfulOutcomes.compactMap { outcome -> InsertionFence? in
            guard case let .alreadyClaimed(fence) = outcome else { return nil }
            return fence
        }
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(alreadyClaimed.count, 1)
        XCTAssertEqual(claimed.first?.claimNonce, alreadyClaimed.first?.claimNonce)

        let reconstructedStore = AppGroupStore(
            defaults: UserDefaults(suiteName: "openwhispr.ios.feasibility.tests.\(UUID().uuidString)"),
            fileDirectoryURL: directory
        )
        switch try reconstructedStore.claimInsertion(for: result, state: state, at: now.addingTimeInterval(1)) {
        case .alreadyClaimed(let fence):
            XCTAssertEqual(fence.claimNonce, claimed.first?.claimNonce)
        default:
            XCTFail("a new store instance must reconstruct the claimed fence")
        }

        let claim = try XCTUnwrap(claimed.first)
        let markedInserted = try reconstructedStore.markInsertionInserted(
            resultID: result.resultID,
            sessionID: state.sessionID!,
            dictationID: result.dictationID,
            claimNonce: claim.claimNonce!,
            at: now.addingTimeInterval(2)
        )
        XCTAssertTrue(markedInserted)
        switch try storeB.claimInsertion(for: result, state: state, at: now.addingTimeInterval(3)) {
        case .alreadyInserted:
            break
        default:
            XCTFail("a finalized insertion fence must reject another claim")
        }
    }

    func testMalformedProtocolFilesThrowInsteadOfAuthorizingWork() throws {
        let (directory, storeA, _) = try makeStores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = Data("not-json".utf8)

        try corrupt.write(
            to: directory.appendingPathComponent(AppGroupConstants.commandQueueFileName),
            options: [.atomic]
        )
        XCTAssertThrowsError(try storeA.nextCommand())

        try corrupt.write(
            to: directory.appendingPathComponent(AppGroupConstants.insertionFencesFileName),
            options: [.atomic]
        )
        let now = Date()
        let result = TranscriptResult(
            resultID: "result-2",
            dictationID: "dictation-2",
            text: "[Fixture transcription] blocked",
            label: "Fixture transcription",
            capReached: false
        )
        let state = SessionState(
            phase: .completed,
            sessionID: "session-2",
            dictationID: result.dictationID,
            result: result,
            hostHeartbeatAt: now,
            sessionExpiresAt: now.addingTimeInterval(60)
        )
        XCTAssertThrowsError(try storeA.claimInsertion(for: result, state: state, at: now))
    }
}
