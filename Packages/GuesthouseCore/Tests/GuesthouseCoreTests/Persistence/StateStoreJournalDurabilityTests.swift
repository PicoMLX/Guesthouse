import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStoreJournalDurabilityTests {
    let fixture = FileManager.default.temporaryDirectory
        .appending(path: "StateStoreJournalDurability-\(UUID().uuidString)")

    @Test(arguments: [false, true])
    func replacementDuringFinalDirectoryBarrierRefusesBegin(replaceDirectory: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "state")
        let detached = fixture.appending(path: "detached")
        let store = try StateStore(rootURL: root, directoryBarrier: { descriptor, name in
            try StateStore.fullySynchronize(descriptor, name: name)
            if replaceDirectory {
                try FileManager.default.moveItem(at: root, to: detached)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            } else {
                let journal = root.appending(path: StateStore.journalFileName)
                try FileManager.default.moveItem(at: journal, to: detached)
                try Data().write(to: journal)
            }
        })
        let cause: StateStoreError = replaceDirectory
            ? .insecureDirectory(reason: "the folder was renamed, removed, or replaced while Guesthouse was using it")
            : .fileUnwritable(name: StateStore.journalFileName)
        let expected = StateStoreError.journalWriteUncertain(cause: cause)
        await #expect(throws: expected) { try await store.begin(.startEnvironment, for: EnvironmentID()) }
        #expect(expected.recoveryActions.first == .inspectState)
        let retainedJournal = replaceDirectory ? detached.appending(path: StateStore.journalFileName) : detached
        #expect(!(try Data(contentsOf: retainedJournal)).isEmpty)
        let reopened = try StateStore(rootURL: root)
        #expect(try await reopened.replay().records.isEmpty)
    }

    @Test func aFailedDirectoryBarrierRequiresInspectionBeforeRetry() async throws {
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "state")
        let failedOnce = fixture.appending(path: "failed-once")
        let failure = StateStoreError.fileUnwritable(name: "state")
        let store = try StateStore(rootURL: root, directoryBarrier: { descriptor, name in
            if !FileManager.default.fileExists(atPath: failedOnce.path) {
                try Data().write(to: failedOnce)
                throw failure
            }
            try StateStore.fullySynchronize(descriptor, name: name)
        })
        let environment = EnvironmentID()
        await #expect(throws: StateStoreError.journalWriteUncertain(cause: failure)) {
            try await store.begin(.startEnvironment, for: environment)
        }
        let started = try #require(try await store.replay().inFlight.values.first)
        await #expect(throws: StateStoreError.operationUnresolved(started.id)) {
            try await store.begin(.startEnvironment, for: environment)
        }
        // Only inspection can settle the uncertain start; completing that record retries the
        // failed directory barrier and leaves a readable, durably reconciled journal.
        try await store.append(JournalRecord(id: started.id, environmentID: environment,
                                            operation: .startEnvironment, timestamp: Date(), outcome: .notApplied))
        #expect(await store.directorySynchronizations == 1)
        #expect(try await store.replay().inFlight.isEmpty)
    }
}
