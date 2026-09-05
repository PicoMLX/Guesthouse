import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStoreJournalRecoveryTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "StateStoreJournalRecovery-\(UUID().uuidString)")

    @Test func failedOutcomeWriteOffersInspectionAndPreservesEvidence() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await original.begin(.startEnvironment, for: environment)
        let journalURL = root.appending(path: StateStore.journalFileName)
        let startedEvidence = try Data(contentsOf: journalURL)
        let cause = StateStoreError.fileUnwritable(name: root.lastPathComponent)
        let store = try StateStore(rootURL: root, directoryBarrier: { _, _ in throw cause })
        let completed = JournalRecord(id: id, environmentID: environment,
                                      operation: .startEnvironment, timestamp: Date(), outcome: .completed)

        do {
            try await store.append(completed)
            Issue.record("The failed directory barrier must refuse the outcome write")
        } catch let failure as StateStoreError {
            #expect(failure == .journalWriteUncertain(cause: cause))
            #expect(failure.recoveryActions == [.inspectState, .freeDiskSpace, .openSettings, .cancel])
            #expect(failure.userMessage.contains(cause.userMessage))
        }

        // The write reached disk before its directory barrier failed. Preserve the outcome
        // as evidence for inspection, even though append could not report it durably saved.
        let retainedEvidence = try Data(contentsOf: journalURL)
        #expect(retainedEvidence.starts(with: startedEvidence))
        #expect(retainedEvidence.count > startedEvidence.count)
        let reopened = try StateStore(rootURL: root)
        let replay = try await reopened.replay()
        #expect(replay.records.count == 2)
        #expect(replay.records.last == completed)
        #expect(!replay.truncatedTail)
        #expect(try Data(contentsOf: journalURL) == retainedEvidence)
    }

    @Test func encodingFailureKeepsItsErrorAndJournalEvidence() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        let journalURL = root.appending(path: StateStore.journalFileName)
        let evidence = try Data(contentsOf: journalURL)
        let unencodable = JournalRecord(id: id, environmentID: environment, operation: .startEnvironment,
                                        timestamp: Date(timeIntervalSinceReferenceDate: .infinity), outcome: .completed)

        await #expect(throws: StateStoreError.unencodable(name: StateStore.journalFileName)) {
            try await store.append(unencodable)
        }

        #expect(try Data(contentsOf: journalURL) == evidence)
        #expect(try await store.replay().inFlight[id]?.outcome == .started)
    }

    @Test func identityFailureKeepsItsErrorAndJournalEvidence() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        let journalURL = root.appending(path: StateStore.journalFileName)
        let evidence = try Data(contentsOf: journalURL)
        let inconsistent = JournalRecord(id: id, environmentID: EnvironmentID(), operation: .startEnvironment,
                                         timestamp: Date(), outcome: .completed)

        await #expect(throws: StateStoreError.inconsistentRecord(id)) {
            try await store.append(inconsistent)
        }

        #expect(try Data(contentsOf: journalURL) == evidence)
        #expect(try await store.replay().inFlight[id]?.environmentID == environment)
    }
}
