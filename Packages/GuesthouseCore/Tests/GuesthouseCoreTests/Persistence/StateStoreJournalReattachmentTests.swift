import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStoreJournalReattachmentTests {
    let fixture = FileManager.default.temporaryDirectory
        .appending(path: "StateStoreJournalReattachment-\(UUID().uuidString)")

    @Test func reattachedJournalIsSynchronizedAgainAndUnchangedBytesStayCached() async throws {
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "state")
        let store = try StateStore(rootURL: root)
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        #expect(await store.directorySynchronizations == 1)

        try Self.reattachJournalWithoutSynchronizing(in: root)

        let accepted = try await store.begin(.stopEnvironment, for: EnvironmentID())
        #expect(await store.directorySynchronizations == 2)
        let bytesRead = await store.journalBytesRead
        #expect(bytesRead > 0)

        // Every append barriers the entry, but the store remembers its own write's version
        // and does not reread unchanged history.
        _ = try await store.begin(.exportWork, for: EnvironmentID())
        #expect(await store.directorySynchronizations == 3)
        #expect(await store.journalBytesRead == bytesRead)
        #expect(try await store.replay().inFlight[accepted]?.operation == .stopEnvironment)
    }

    @Test func failedReattachmentBarrierPreservesEvidenceAndRequiresInspectionBeforeRetry() async throws {
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "state")
        let failBarrier = fixture.appending(path: "fail-barrier")
        let cause = StateStoreError.fileUnwritable(name: root.lastPathComponent)
        let store = try StateStore(rootURL: root, directoryBarrier: { descriptor, name in
            if FileManager.default.fileExists(atPath: failBarrier.path) { throw cause }
            try StateStore.fullySynchronize(descriptor, name: name)
        })
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        #expect(await store.directorySynchronizations == 1)
        try Self.reattachJournalWithoutSynchronizing(in: root)
        let journalURL = root.appending(path: StateStore.journalFileName)
        let priorEvidence = try Data(contentsOf: journalURL)
        try Data().write(to: failBarrier)

        let environment = EnvironmentID()
        do {
            _ = try await store.begin(.stopEnvironment, for: environment)
            Issue.record("An unsynchronized reattached journal must not authorize the operation")
        } catch let failure as StateStoreError {
            #expect(failure == .journalWriteUncertain(cause: cause))
            #expect(failure.recoveryActions.first == .inspectState)
        }
        #expect(await store.directorySynchronizations == 1)
        let retainedEvidence = try Data(contentsOf: journalURL)
        #expect(retainedEvidence.starts(with: priorEvidence))
        #expect(retainedEvidence.count > priorEvidence.count)
        let replay = try await store.replay()
        let uncertain = try #require(replay.inFlight.values.first { $0.environmentID == environment })
        #expect(replay.records.count == 2)
        #expect(uncertain.operation == .stopEnvironment)
        #expect(uncertain.outcome == .started)
        #expect(!replay.truncatedTail)
        await #expect(throws: StateStoreError.operationUnresolved(uncertain.id)) {
            try await store.begin(.stopEnvironment, for: environment)
        }
        #expect(try Data(contentsOf: journalURL) == retainedEvidence)

        // Inspection can establish that the refused operation did not start; recording that
        // result must retry the failed directory barrier before recovery can proceed.
        try FileManager.default.removeItem(at: failBarrier)
        try await store.append(JournalRecord(id: uncertain.id, environmentID: environment,
                                            operation: .stopEnvironment, timestamp: Date(), outcome: .notApplied))
        #expect(await store.directorySynchronizations == 2)
        #expect(try await store.replay().inFlight[uncertain.id] == nil)
        #expect((try Data(contentsOf: journalURL)).starts(with: retainedEvidence))
    }

    @Test func reattachmentDuringFinalBarrierRefusesAuthorizationAndPreservesEvidence() async throws {
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "state")
        let store = try StateStore(rootURL: root, directoryBarrier: { descriptor, name in
            try StateStore.fullySynchronize(descriptor, name: name)
            try Self.reattachJournalWithoutSynchronizing(in: root)
        })
        let environment = EnvironmentID()
        var authorizedID: OperationID?
        do {
            authorizedID = try await store.begin(.startEnvironment, for: environment)
        } catch let failure as StateStoreError {
            #expect(failure == .journalWriteUncertain(cause: .fileUnwritable(name: StateStore.journalFileName)))
            #expect(failure.recoveryActions.first == .inspectState)
        }
        #expect(authorizedID == nil)
        #expect(await store.directorySynchronizations == 1)

        // The same inode returned with its record intact, but its name was reattached after
        // the completed directory barrier. The record is inspection evidence, not permission
        // to begin the mutation or to retry it blindly.
        let journalURL = root.appending(path: StateStore.journalFileName)
        let evidence = try Data(contentsOf: journalURL)
        let replay = try await store.replay()
        let uncertain = try #require(replay.inFlight.values.first)
        #expect(replay.records.count == 1)
        #expect(uncertain.environmentID == environment)
        #expect(uncertain.operation == .startEnvironment)
        #expect(uncertain.outcome == .started)
        #expect(!replay.truncatedTail)
        await #expect(throws: StateStoreError.operationUnresolved(uncertain.id)) {
            try await store.begin(.startEnvironment, for: environment)
        }
        #expect(try Data(contentsOf: journalURL) == evidence)
    }

    private static func reattachJournalWithoutSynchronizing(in root: URL) throws {
        let journal = root.appending(path: StateStore.journalFileName)
        let detached = root.appending(path: "detached-journal")
        let evidence = try Data(contentsOf: journal)
        var before = stat()
        try #require(lstat(journal.path, &before) == 0)
        try #require(rename(journal.path, detached.path) == 0)
        var missing = stat()
        let missingResult = lstat(journal.path, &missing)
        let missingError = errno
        try #require(missingResult == -1 && missingError == ENOENT)
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(directory >= 0)
        defer { close(directory) }
        // Persist the absence of the canonical journal entry, then restore the same inode
        // without a directory barrier. No timestamp writes or timing delays are involved.
        try StateStore.fullySynchronize(directory, name: root.lastPathComponent)
        try #require(rename(detached.path, journal.path) == 0)
        var after = stat()
        try #require(lstat(journal.path, &after) == 0)
        try #require(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
        try #require(before.st_size == after.st_size)
        try #require(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
        try #require(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        try #require(before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
                     || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec,
                     "The real rename must change ctime so the journal version detects reattachment")
        try #require(Data(contentsOf: journal) == evidence)
    }
}
