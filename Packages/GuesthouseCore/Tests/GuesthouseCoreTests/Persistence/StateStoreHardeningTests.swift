import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStoreHardeningTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "StateStoreHardening-\(UUID().uuidString)")

    func mode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1
    }

    func snapshot(_ environments: [DevelopmentEnvironment]) throws -> EnvironmentsSnapshot {
        var slots = VMSlotInventory()
        for environment in environments { try slots.reserve(environment.id) }
        return EnvironmentsSnapshot(environments: environments, slots: slots)
    }

    @Test func tornTailIsTruncatedBeforeTheNextAppend() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        let handle = try FileHandle(forWritingTo: await store.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"format\":1,\"id\":\"torn".utf8))
        try handle.close()
        #expect(try await store.replay().truncatedTail)
        try await store.append(JournalRecord(id: id, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: .completed))
        let replay = try await store.replay()
        #expect(replay.records.count == 2)
        #expect(!replay.truncatedTail)
        #expect(replay.inFlight.isEmpty)
    }

    @Test func symlinkedFilesAreRefusedAndWideModesNarrowed() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let elsewhere = root.appending(path: "elsewhere.ndjson")
        try Data().write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: root.appending(path: StateStore.journalFileName), withDestinationURL: elsewhere)
        let store = try StateStore(rootURL: root)
        await #expect(throws: StateStoreError.insecureDirectory(reason: "journal.ndjson is a symbolic link")) {
            try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        try FileManager.default.removeItem(at: root.appending(path: StateStore.journalFileName))
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: await store.journalURL.path)
        _ = try await store.begin(.stopEnvironment, for: EnvironmentID())
        #expect(try mode(await store.journalURL) == 0o600)
        try await store.saveSnapshot(.empty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: await store.snapshotURL.path)
        _ = try await store.loadSnapshot()
        #expect(try mode(await store.snapshotURL) == 0o600)
    }

    @Test func emptyLinesBetweenRecordsAreCorruption() async throws {
        let store = try StateStore(rootURL: root)
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        let url = await store.journalURL
        var data = try Data(contentsOf: url)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await store.replay() }
    }

    @Test func unknownOutcomeFailuresStayInFlightAndIdentityIsRetained() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        try await store.append(JournalRecord(id: id, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: .failed(.operationOutcomeUnknown(id))))
        #expect(try await store.replay().inFlight.keys.contains(id))
        await #expect(throws: StateStoreError.inconsistentRecord(id)) {
            try await store.append(JournalRecord(id: id, environmentID: EnvironmentID(), operation: .startEnvironment, timestamp: Date(), outcome: .completed))
        }
        await #expect(throws: StateStoreError.inconsistentRecord(id)) {
            try await store.append(JournalRecord(id: id, environmentID: environment, operation: .stopEnvironment, timestamp: Date(), outcome: .completed))
        }
        let stranger = OperationID()
        await #expect(throws: StateStoreError.inconsistentRecord(stranger)) {
            try await store.append(JournalRecord(id: stranger, environmentID: environment, operation: .stopEnvironment, timestamp: Date(), outcome: .completed))
        }
        #expect(try await store.replay().records.count == 2)
    }

    @Test func inconsistentSnapshotsAreRejectedOnSaveAndLoad() async throws {
        let store = try StateStore(rootURL: root)
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: Date())
        let duplicate = EnvironmentsSnapshot(environments: [environment, environment])
        await #expect(throws: StateStoreError.inconsistentSnapshot(reason: "two environments share one identity")) { try await store.saveSnapshot(duplicate) }
        let noSlot = EnvironmentsSnapshot(environments: [environment])
        await #expect(throws: StateStoreError.inconsistentSnapshot(reason: "environments and VM slots disagree")) { try await store.saveSnapshot(noSlot) }
        let good = try snapshot([environment])
        try await store.saveSnapshot(good)
        var text = String(decoding: try Data(contentsOf: await store.snapshotURL), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"slots\" : [", with: "\"slots\" : [ {\"environmentID\" : \"\(UUID().uuidString)\", \"state\" : \"active\"},")
        try Data(text.utf8).write(to: await store.snapshotURL)
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
    }

    @Test func datesRoundTripExactly() async throws {
        let store = try StateStore(rootURL: root)
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.123456789))
        let saved = try snapshot([environment])
        try await store.saveSnapshot(saved)
        #expect(try await store.loadSnapshot() == saved)
    }

    @Test func recordFormatsThisBuildCannotReadAreRejected() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        let record = JournalRecord(id: id, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: .completed)
        let current = JournalRecord.currentFormat
        var json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(json.contains("\"format\":\(current)"), "a record this build writes carries this build's format")
        // A record from a later build is refused by name, so the journal is never reported as
        // corrupt when the only problem is that it is newer.
        json = json.replacingOccurrences(of: "\"format\":\(current)", with: "\"format\":\(current + 1)")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8)) }
        // Every format this build claims to read still decodes.
        for older in 1..<current {
            let downgraded = json.replacingOccurrences(of: "\"format\":\(current + 1)", with: "\"format\":\(older)")
            #expect(throws: Never.self) { try JSONDecoder().decode(JournalRecord.self, from: Data(downgraded.utf8)) }
        }
    }

    @Test func migrationsMustAdvanceExactlyOneVersion() {
        let skipping = SnapshotMigrator(current: SchemaVersion(3)!, migrations: [
            SnapshotMigrator.Migration(from: SchemaVersion(1)!) { _ in Data("{\"schemaVersion\":3}".utf8) },
        ])
        #expect(throws: StateStoreError.migrationProducedWrongVersion(from: SchemaVersion(1)!, produced: SchemaVersion(3)!)) {
            try skipping.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }

    @Test func aSecondStartOnAnUnresolvedEnvironmentIsRefused() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let first = try await store.begin(.startEnvironment, for: environment)
        await #expect(throws: StateStoreError.operationUnresolved(first)) {
            try await store.begin(.stopEnvironment, for: environment)
        }
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        try await store.append(JournalRecord(id: first, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: .failed(.operationOutcomeUnknown(first))))
        await #expect(throws: StateStoreError.operationUnresolved(first)) {
            try await store.begin(.stopEnvironment, for: environment)
        }
        try await store.append(JournalRecord(id: first, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: .completed))
        _ = try await store.begin(.stopEnvironment, for: environment)
    }

    @Test func aRootThatCannotBeCreatedIsReportedAsUnwritable() {
        #expect(throws: StateStoreError.fileUnwritable(name: "state")) { try StateStore(rootURL: URL(fileURLWithPath: "/dev/null/state")) }
    }

    @Test func everyStoreErrorIsActionable() {
        let errors: [StateStoreError] = [
            .operationUnresolved(OperationID()),
            .insecureDirectory(reason: "x"), .corruptSnapshot, .inconsistentSnapshot(reason: "x"), .corruptJournal(line: 1),
            .unsupportedJournalFormat(line: 1, format: 2), .migrationFailed(from: SchemaVersion(1)!),
            .inconsistentRecord(OperationID()), .newerSchemaVersion(found: SchemaVersion(2)!, current: SchemaVersion(1)!),
            .migrationMissing(from: SchemaVersion(1)!), .migrationProducedWrongVersion(from: SchemaVersion(1)!, produced: SchemaVersion(3)!),
            .duplicateMigration(from: SchemaVersion(1)!), .fileUnwritable(name: "x"), .fileUnreadable(name: "x"), .unencodable(name: "x"),
        ]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
            #expect(error.errorDescription == error.userMessage)
        }
    }

    // MARK: - Unresolved outcomes

    @Test func canceledMutationsStayUnresolvedUntilTheyAreSettled() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.provision(stage: .guestSecured), for: environment)
        try await store.append(JournalRecord(id: id, environmentID: environment, operation: .provision(stage: .guestSecured), timestamp: Date(), outcome: .failed(.canceled)))
        #expect(try await store.replay().inFlight.keys.contains(id))
        await #expect(throws: StateStoreError.operationUnresolved(id)) {
            try await store.begin(.provision(stage: .guestSecured), for: environment)
        }
        try await store.append(JournalRecord(id: id, environmentID: environment, operation: .provision(stage: .guestSecured), timestamp: Date(), outcome: .completed))
        #expect(try await store.replay().inFlight.isEmpty)
        _ = try await store.begin(.provision(stage: .xcodeToolsReady), for: environment)
    }

    @Test func nothingIsRecordedAgainstASettledOperation() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        try await store.append(JournalRecord(id: id, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: .completed))
        for late: JournalRecord.Outcome in [.checkpoint(.runtimeReady), .unknown, .completed, .failed(.canceled)] {
            await #expect(throws: StateStoreError.inconsistentRecord(id)) {
                try await store.append(JournalRecord(id: id, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: late))
            }
        }
        #expect(try await store.replay().inFlight.isEmpty)

        // The same rule holds for a journal written by something else.
        let late = JournalRecord(id: id, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: .unknown)
        var line = try JSONEncoder().encode(late)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: await store.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()
        await #expect(throws: StateStoreError.corruptJournal(line: 3)) { try await store.replay() }
    }

    @Test func anUnknownOutcomeMustNameItsOwnOperation() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.stopEnvironment, for: environment)
        await #expect(throws: StateStoreError.inconsistentRecord(id)) {
            try await store.append(JournalRecord(id: id, environmentID: environment, operation: .stopEnvironment, timestamp: Date(), outcome: .failed(.operationOutcomeUnknown(OperationID()))))
        }
        try await store.append(JournalRecord(id: id, environmentID: environment, operation: .stopEnvironment, timestamp: Date(), outcome: .failed(.operationOutcomeUnknown(id))))
        #expect(try await store.replay().records.count == 2)
    }

    // MARK: - Files the store did not create

    @Test func aStateFileWithASecondNameIsRefused() async throws {
        let store = try StateStore(rootURL: root)
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        let elsewhere = root.appending(path: "shared.ndjson")
        #expect(link(await store.journalURL.path, elsewhere.path) == 0)
        await #expect(throws: StateStoreError.insecureDirectory(reason: "journal.ndjson has more than one name")) {
            try await store.begin(.stopEnvironment, for: EnvironmentID())
        }
    }

    @Test func aNamedPipeInPlaceOfAStateFileIsRefusedWithoutWaitingForAWriter() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(mkfifo(root.appending(path: StateStore.journalFileName).path, 0o600) == 0)
        #expect(mkfifo(root.appending(path: StateStore.snapshotFileName).path, 0o600) == 0)
        let store = try StateStore(rootURL: root)
        await #expect(throws: StateStoreError.insecureDirectory(reason: "journal.ndjson is not a regular file")) {
            try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        await #expect(throws: StateStoreError.insecureDirectory(reason: "environments.json is not a regular file")) {
            try await store.loadSnapshot()
        }
    }

    @Test func extendedACLsAreRemovedAlongWithAWideMode() async throws {
        let store = try StateStore(rootURL: root)
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        let journal = await store.journalURL
        try grantExtendedACL(at: journal)
        #expect(hasExtendedACL(at: journal))
        _ = try await store.replay()
        #expect(!hasExtendedACL(at: journal))

        try grantExtendedACL(at: root)
        #expect(hasExtendedACL(at: root))
        _ = try StateStore(rootURL: root)
        #expect(!hasExtendedACL(at: root))
    }

    // MARK: - Durability

    @Test func theJournalEntryIsSynchronizedEvenWhenTheFileAlreadyExisted() async throws {
        let first = try StateStore(rootURL: root)
        _ = try await first.begin(.startEnvironment, for: EnvironmentID())
        _ = try await first.begin(.stopEnvironment, for: EnvironmentID())
        // Once per process, not once per record.
        #expect(await first.directorySynchronizations == 1)

        // A journal left by an earlier process may never have had its entry synchronized, so
        // its existence is not proof and the next process synchronizes it again.
        let second = try StateStore(rootURL: root)
        _ = try await second.begin(.exportWork, for: EnvironmentID())
        #expect(await second.directorySynchronizations == 1)
    }

    @Test func appendingReadsOnlyWhatIsNewInTheJournal() async throws {
        let store = try StateStore(rootURL: root)
        for _ in 0..<200 { _ = try await store.begin(.startEnvironment, for: EnvironmentID()) }
        let size = try #require(FileManager.default.attributesOfItem(atPath: await store.journalURL.path)[.size] as? Int)
        #expect(size > 20_000)
        // Nothing was appended by anyone else, so nothing had to be read back.
        #expect(await store.journalBytesRead == 0)

        let stranger = try StateStore(rootURL: root)
        _ = try await stranger.replay()
        #expect(await stranger.journalBytesRead == size)
        _ = try await store.begin(.stopEnvironment, for: EnvironmentID())
        #expect(await store.journalBytesRead == 0)
    }

    @Test func aFullBarrierIsRequiredAndNeverSilentlySkipped() throws {
        let file = root.appending(path: "barrier")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)))
        let descriptor = open(file.path, O_WRONLY)
        defer { close(descriptor) }
        try StateStore.fullySynchronize(descriptor, name: "barrier")

        // A descriptor that can offer neither barrier reports a storage failure rather than
        // letting the caller believe the bytes are durable.
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        defer { close(ends[0]); close(ends[1]) }
        #expect(throws: StateStoreError.fileUnwritable(name: "pipe")) {
            try StateStore.fullySynchronize(ends[1], name: "pipe")
        }
    }

    @Test func everyDirectoryCreatedForTheStoreIsListed() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let deep = root.appending(path: "a/b/c")
        // Deepest first: each one's entry has to be made durable in its own parent.
        #expect(StateStore.directoriesToCreate(for: deep).map(\.lastPathComponent) == ["c", "b", "a"])
        _ = try StateStore(rootURL: deep)
        #expect(StateStore.directoriesToCreate(for: deep).isEmpty)
        for path in ["a", "a/b", "a/b/c"] {
            #expect(try mode(root.appending(path: path)) == 0o700)
        }
    }

    @Test func twoStoresOnOneDirectoryDoNotOverwriteEachOthersRecords() async throws {
        let first = try StateStore(rootURL: root)
        let second = try StateStore(rootURL: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<25 { _ = try await first.begin(.startEnvironment, for: EnvironmentID()) }
            }
            group.addTask {
                for _ in 0..<25 { _ = try await second.begin(.stopEnvironment, for: EnvironmentID()) }
            }
            try await group.waitForAll()
        }
        let replay = try await first.replay()
        #expect(replay.records.count == 50)
        #expect(!replay.truncatedTail)
        #expect(replay.inFlight.count == 50)
    }

    // MARK: - Values that cannot be written or read

    @Test func aValueThatCannotBeEncodedIsAStoreError() async throws {
        let store = try StateStore(rootURL: root)
        let impossible = try snapshot([DevelopmentEnvironment(name: "Dev", createdAt: Date(timeIntervalSinceReferenceDate: .infinity))])
        await #expect(throws: StateStoreError.unencodable(name: StateStore.snapshotFileName)) {
            try await store.saveSnapshot(impossible)
        }
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        await #expect(throws: StateStoreError.unencodable(name: StateStore.journalFileName)) {
            try await store.append(JournalRecord(id: id, environmentID: environment, operation: .startEnvironment, timestamp: Date(timeIntervalSinceReferenceDate: .infinity), outcome: .completed))
        }
    }

    @Test func aRecordFromAnotherSchemaVersionIsNeverSavedOrLoaded() async throws {
        let store = try StateStore(rootURL: root)
        let future = try snapshot([DevelopmentEnvironment(name: "Dev", createdAt: Date(), schemaVersion: SchemaVersion(99)!)])
        await #expect(throws: StateStoreError.inconsistentSnapshot(reason: "a development Mac record with another schema version")) {
            try await store.saveSnapshot(future)
        }
        try await store.saveSnapshot(try snapshot([DevelopmentEnvironment(name: "Dev", createdAt: Date())]))
        var text = String(decoding: try Data(contentsOf: await store.snapshotURL), as: UTF8.self)
        // The first version in the document is the environment's own, not the snapshot's.
        let nested = try #require(text.range(of: "\"schemaVersion\" : 1"))
        text.replaceSubrange(nested, with: "\"schemaVersion\" : 99")
        try Data(text.utf8).write(to: await store.snapshotURL)
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
    }

    // MARK: - Snapshot documents the store did not write

    @Test func malformedSnapshotJSONIsReportedAsCorruption() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshotURL = root.appending(path: StateStore.snapshotFileName)
        let store = try StateStore(rootURL: root)
        for text in ["{ \"environments\" : ", "[]", ""] {
            try Data(text.utf8).write(to: snapshotURL)
            await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
        }
    }

    @Test func aBooleanSchemaVersionIsNotVersionZero() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = """
        {"schemaVersion":false,"environments":[],"provisioning":{},"slots":{"slots":[]}}
        """
        try Data(text.utf8).write(to: root.appending(path: StateStore.snapshotFileName))
        let store = try StateStore(rootURL: root)
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
    }

    // MARK: - Journals written by something other than this store

    /// Appending checks that a record agrees with itself; replay used to trust the file instead,
    /// so a restored or repaired journal could put a record naming two operations, two
    /// development Macs, or two stages in front of recovery.
    @Test func replayHoldsRestoredRecordsToTheRulesAppendingApplies() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.provision(stage: .sshPaired), for: environment)
        let contradictions: [(record: JournalRecord, refusal: StateStoreError)] = [
            (JournalRecord(id: id, environmentID: environment, operation: .provision(stage: .sshPaired), timestamp: Date(), outcome: .failed(.operationOutcomeUnknown(OperationID()))), .inconsistentRecord(id)),
            (JournalRecord(id: id, environmentID: environment, operation: .provision(stage: .sshPaired), timestamp: Date(), outcome: .checkpoint(.guestSecured)), .inconsistentRecord(id)),
            (JournalRecord(id: id, environmentID: environment, operation: .provision(stage: .sshPaired), timestamp: Date(), outcome: .failed(.guestNotReachable(EnvironmentID()))), .inconsistentRecord(id)),
            (JournalRecord(id: id, environmentID: environment, operation: .provision(stage: .sshPaired), timestamp: Date(), outcome: .failed(.hostKeyChanged(EnvironmentID()))), .inconsistentRecord(id)),
            // A second live mutation on one development Mac: the store refuses to create this
            // state, so finding it in the file means the file is not to be trusted.
            (JournalRecord(id: OperationID(), environmentID: environment, operation: .stopEnvironment, timestamp: Date(), outcome: .started), .operationUnresolved(id)),
        ]
        let url = await store.journalURL
        let intact = try Data(contentsOf: url)
        for (record, refusal) in contradictions {
            try intact.write(to: url)
            await #expect(throws: refusal, "\(record.outcome)") { try await store.append(record) }
            var line = try JSONEncoder().encode(record)
            line.append(0x0A)
            try (intact + line).write(to: url)
            let reopened = try StateStore(rootURL: root)
            await #expect(throws: StateStoreError.corruptJournal(line: 2), "\(record.outcome)") {
                try await reopened.replay()
            }
        }
    }

    /// A record whose format this build cannot read is not damage: the journal is intact and a
    /// newer Guesthouse can read it, so the user is offered the update, not an inspection.
    @Test func aNewerRecordFormatIsReportedAsSuchNotAsDamage() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        _ = try await store.begin(.startEnvironment, for: environment)
        let future = JournalRecord(id: OperationID(), environmentID: environment, operation: .stopEnvironment, timestamp: Date(), outcome: .started)
        var text = String(decoding: try JSONEncoder().encode(future), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"format\":1", with: "\"format\":2")
        let handle = try FileHandle(forWritingTo: await store.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((text + "\n").utf8))
        try handle.close()
        let reopened = try StateStore(rootURL: root)
        await #expect(throws: StateStoreError.unsupportedJournalFormat(line: 2, format: 2)) { try await reopened.replay() }
        #expect(StateStoreError.unsupportedJournalFormat(line: 2, format: 2).recoveryActions.contains(.reinstallApp))
    }

    /// Formats start at 1, so a record declaring zero or a negative one came from damage rather
    /// than from a newer release: telling the user to update could not repair it.
    @Test func aNonPositiveRecordFormatIsDamageNotANewerRelease() async throws {
        for format in ["0", "-1"] {
            let root = root.appending(path: "format\(format)")
            let store = try StateStore(rootURL: root)
            let environment = EnvironmentID()
            _ = try await store.begin(.startEnvironment, for: environment)
            let broken = JournalRecord(id: OperationID(), environmentID: environment, operation: .stopEnvironment, timestamp: Date(), outcome: .started)
            let text = String(decoding: try JSONEncoder().encode(broken), as: UTF8.self)
                .replacingOccurrences(of: "\"format\":1", with: "\"format\":\(format)")
            let handle = try FileHandle(forWritingTo: await store.journalURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((text + "\n").utf8))
            try handle.close()
            let reopened = try StateStore(rootURL: root)
            await #expect(throws: StateStoreError.corruptJournal(line: 2)) { try await reopened.replay() }
        }
        #expect(StateStoreError.corruptJournal(line: 2).recoveryActions.contains(.inspectState))
    }

    /// A complete final record that lost only its newline used to be discarded as a torn write,
    /// so the mutation it started disappeared from replay and the next one could run without
    /// anything being inspected.
    @Test func aFinalRecordMissingOnlyItsNewlineIsStillARecord() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        let url = await store.journalURL
        var bytes = try Data(contentsOf: url)
        #expect(bytes.last == 0x0A)
        bytes.removeLast()
        try bytes.write(to: url)

        let reopened = try StateStore(rootURL: root)
        let replay = try await reopened.replay()
        #expect(!replay.truncatedTail)
        #expect(replay.records.count == 1)
        #expect(replay.inFlight.keys.contains(id))
        await #expect(throws: StateStoreError.operationUnresolved(id)) {
            try await reopened.begin(.stopEnvironment, for: environment)
        }
        // The next record supplies the missing newline instead of fusing onto the line before it.
        try await reopened.append(JournalRecord(id: id, environmentID: environment, operation: .startEnvironment, timestamp: Date(), outcome: .completed))
        let settled = try await StateStore(rootURL: root).replay()
        #expect(settled.records.count == 2)
        #expect(settled.inFlight.isEmpty)
        #expect(!settled.truncatedTail)
    }

    /// A journal rewritten in place keeps its inode and can keep its length, so the remembered
    /// replay used to be reused for a file whose records had all been replaced.
    @Test func aJournalRewrittenInPlaceIsReadAgain() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let first = try await store.begin(.startEnvironment, for: environment)
        #expect(try await store.replay().inFlight.keys.contains(first))

        // Same inode, same length: only the operation's identity changes.
        let url = await store.journalURL
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let replacement = OperationID()
        let rewritten = text.replacingOccurrences(of: first.uuid.uuidString, with: replacement.uuid.uuidString)
        #expect(rewritten.utf8.count == text.utf8.count)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(rewritten.utf8))
        try handle.close()

        let replay = try await store.replay()
        #expect(replay.inFlight.keys.contains(replacement))
        #expect(!replay.inFlight.keys.contains(first))
    }

    /// A journal that was replaced after this store synchronized an earlier one's entry may have
    /// arrived through an unsynchronized restore, so its own entry is synchronized again.
    @Test func aReplacedJournalHasItsDirectoryEntrySynchronizedAgain() async throws {
        let store = try StateStore(rootURL: root)
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        #expect(await store.directorySynchronizations == 1)
        try FileManager.default.removeItem(at: await store.journalURL)
        _ = try await store.begin(.stopEnvironment, for: EnvironmentID())
        #expect(await store.directorySynchronizations == 2)
    }

    /// Inspection can establish that an interrupted mutation never took effect. Without a record
    /// for that, recovery had to choose between claiming it completed and leaving the
    /// development Mac blocked against every new operation.
    @Test func aMutationInspectionFoundDidNotApplyCanBeSettledTruthfully() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let lost = try await store.begin(.provision(stage: .macOSInstalled), for: environment)
        try await store.append(JournalRecord(id: lost, environmentID: environment, operation: .provision(stage: .macOSInstalled), timestamp: Date(), outcome: .unknown))
        await #expect(throws: StateStoreError.operationUnresolved(lost)) {
            try await store.begin(.provision(stage: .macOSInstalled), for: environment)
        }
        try await store.append(JournalRecord(id: lost, environmentID: environment, operation: .provision(stage: .macOSInstalled), timestamp: Date(), outcome: .notApplied))
        #expect(try await store.replay().inFlight.isEmpty)
        _ = try await store.begin(.provision(stage: .macOSInstalled), for: environment)
        // Terminal like any other result: nothing may be recorded against it afterwards.
        await #expect(throws: StateStoreError.inconsistentRecord(lost)) {
            try await store.append(JournalRecord(id: lost, environmentID: environment, operation: .provision(stage: .macOSInstalled), timestamp: Date(), outcome: .completed))
        }
    }

    // MARK: - Files and directories the store did not create

    /// The store refuses a state file with a second name everywhere it opens one; replacing the
    /// snapshot used to go straight to the rename, which repoints this entry and leaves the old
    /// bytes, and the permissions they carry, alive under the other name.
    @Test func aSnapshotWithASecondNameIsRefusedBeforeItIsReplaced() async throws {
        let store = try StateStore(rootURL: root)
        try await store.saveSnapshot(.empty)
        let elsewhere = root.appending(path: "shared.json")
        #expect(link(await store.snapshotURL.path, elsewhere.path) == 0)
        await #expect(throws: StateStoreError.insecureDirectory(reason: "environments.json has more than one name")) {
            try await store.saveSnapshot(.empty)
        }
    }

    /// Cleanup removes what an earlier crash left behind, not what another store on the same
    /// directory is writing right now: unlinking a live temporary makes its rename fail on a
    /// healthy directory.
    @Test func aTemporaryAnotherWriterHoldsSurvivesCleanup() async throws {
        let store = try StateStore(rootURL: root)
        let live = root.appending(path: StateStore.tempPrefix + UUID().uuidString)
        let leftover = root.appending(path: StateStore.tempPrefix + UUID().uuidString)
        #expect(FileManager.default.createFile(atPath: live.path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: leftover.path, contents: Data()))
        let held = open(live.path, O_RDONLY)
        defer { close(held) }
        try #require(held >= 0)
        #expect(flock(held, LOCK_EX) == 0)

        try await store.saveSnapshot(.empty)
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    /// The store writes through a descriptor for the directory it verified at startup. Once that
    /// is no longer the directory at `rootURL`, a record it reports durable is one the next
    /// launch will never find.
    @Test func aStateFolderReplacedUnderTheStoreIsRefused() async throws {
        let store = try StateStore(rootURL: root)
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        try FileManager.default.removeItem(at: root)
        await #expect(throws: StateStoreError.insecureDirectory(reason: "the folder was renamed, removed, or replaced while Guesthouse was using it")) {
            try await store.begin(.stopEnvironment, for: EnvironmentID())
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        await #expect(throws: StateStoreError.insecureDirectory(reason: "the folder was renamed, removed, or replaced while Guesthouse was using it")) {
            try await store.loadSnapshot()
        }
    }

    /// A journal renamed, unlinked, or replaced between the open and the end of the append leaves
    /// the descriptor on a file no name points at any more. The bytes are durable there and
    /// nowhere the next launch will look, so `begin` must not report the operation started.
    @Test func aJournalWhoseEntryChangedUnderTheDescriptorIsNotReportedDurable() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(directory) }
        try #require(directory >= 0)
        let descriptor = openat(directory, StateStore.journalFileName, O_RDWR | O_CREAT, 0o600)
        defer { close(descriptor) }
        try #require(descriptor >= 0)
        try StateStore.requireEntryStillNames(descriptor, in: directory, name: StateStore.journalFileName)

        // The name now belongs to another file; the descriptor still holds the old one.
        try FileManager.default.moveItem(at: root.appending(path: StateStore.journalFileName), to: root.appending(path: "detached.ndjson"))
        #expect(FileManager.default.createFile(atPath: root.appending(path: StateStore.journalFileName).path, contents: Data()))
        #expect(throws: StateStoreError.fileUnwritable(name: StateStore.journalFileName)) {
            try StateStore.requireEntryStillNames(descriptor, in: directory, name: StateStore.journalFileName)
        }
        // And when the name is gone altogether.
        try FileManager.default.removeItem(at: root.appending(path: StateStore.journalFileName))
        #expect(throws: StateStoreError.fileUnwritable(name: StateStore.journalFileName)) {
            try StateStore.requireEntryStillNames(descriptor, in: directory, name: StateStore.journalFileName)
        }
    }

    /// An unreadable access control list is not an absent one: the store cannot establish that
    /// no other principal has access, so it refuses the file instead of assuming.
    @Test func anAccessControlListThatCannotBeReadIsRefused() {
        #expect(throws: StateStoreError.insecureDirectory(reason: "journal.ndjson access control cannot be read")) {
            try StateStore.removeExtendedACL(-1, name: StateStore.journalFileName)
        }
    }

    /// A directory chain whose entries could not be made durable is removed again. Left behind,
    /// the next attempt would find it present, create nothing, and synchronize nothing.
    @Test func directoriesThatCouldNotBeMadeDurableAreRemovedAgain() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let deep = root.appending(path: "a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let created = StateStore.directoriesToCreate(for: deep.appending(path: "d"))
        #expect(throws: StateStoreError.insecureDirectory(reason: "cannot be opened")) {
            try StateStore.makeCreatedDirectoriesDurable([deep, root.appending(path: "a/b"), root.appending(path: "a")]) { _ in
                throw StateStoreError.insecureDirectory(reason: "cannot be opened")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "a").path))
        #expect(created.map(\.lastPathComponent) == ["d"])
    }

    /// The rollback also has to run when a level of the chain cannot be created at all, not
    /// only when one cannot be made durable: the ancestors already made are just as
    /// unsynchronized either way, and the next attempt would find them present and make nothing.
    @Test func directoriesLeftByAFailedCreationAreRemovedAgain() throws {
        // The deepest component is one scalar past `NAME_MAX`, so its parent is created and it
        // is not. Nothing else about the chain is unusual.
        let parent = root.appending(path: "a")
        let unmakeable = parent.appending(path: String(repeating: "n", count: 256))
        #expect(throws: StateStoreError.fileUnwritable(name: unmakeable.lastPathComponent)) {
            _ = try StateStore(rootURL: unmakeable)
        }
        #expect(!FileManager.default.fileExists(atPath: parent.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    /// Two initializations can survey the same missing root before either creates it. The
    /// rollback of the one that fails must not take the other's journal with it, or the store
    /// that already reported a mutation durable would come up with no record of it.
    @Test func aRollbackLeavesADirectoryThatHoldsAnotherStoresWorkAlone() throws {
        let deep = root.appending(path: "a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journal = deep.appending(path: StateStore.journalFileName)
        try Data("{\"format\":1}\n".utf8).write(to: journal)
        #expect(throws: StateStoreError.insecureDirectory(reason: "cannot be opened")) {
            try StateStore.makeCreatedDirectoriesDurable([deep, root.appending(path: "a/b"), root.appending(path: "a")]) { _ in
                throw StateStoreError.insecureDirectory(reason: "cannot be opened")
            }
        }
        #expect(FileManager.default.fileExists(atPath: journal.path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "a").path))
    }

    /// A state one above the ceiling is legitimate in memory — a record decoded at the ceiling
    /// mints its next token above it — and is exactly what `ProvisioningState`'s decoder
    /// refuses, so writing it would report the whole snapshot corrupt on the next launch.
    @Test func aProvisioningCounterTheDecoderWouldRefuseIsNeverWritten() async throws {
        let store = try StateStore(rootURL: root)
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: Date())
        var beyond = try snapshot([environment])
        beyond.provisioning[environment.id] = ProvisioningState(
            stage: .first,
            status: .awaitingInspection(EffectToken(ProvisioningState.maximumIssuedEffects + 1))
        )
        await #expect(throws: StateStoreError.inconsistentSnapshot(reason: "provisioning effect counter is beyond \(ProvisioningState.maximumIssuedEffects)")) {
            try await store.saveSnapshot(beyond)
        }
        var atCeiling = try snapshot([environment])
        atCeiling.provisioning[environment.id] = ProvisioningState(
            stage: .first,
            status: .awaitingInspection(EffectToken(ProvisioningState.maximumIssuedEffects))
        )
        try await store.saveSnapshot(atCeiling)
        #expect(try await store.loadSnapshot() == atCeiling)
    }

    @Test func aMigrationThatFailsForItsOwnReasonsIsStillActionable() {
        struct Unexpected: Error {}
        let failing = SnapshotMigrator(current: SchemaVersion(2)!, migrations: [
            SnapshotMigrator.Migration(from: SchemaVersion(1)!) { _ in throw Unexpected() },
        ])
        #expect(throws: StateStoreError.migrationFailed(from: SchemaVersion(1)!)) {
            try failing.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
        // A migration that reports a store error of its own keeps it.
        let corrupt = SnapshotMigrator(current: SchemaVersion(2)!, migrations: [
            SnapshotMigrator.Migration(from: SchemaVersion(1)!) { _ in throw StateStoreError.corruptSnapshot },
        ])
        #expect(throws: StateStoreError.corruptSnapshot) {
            try corrupt.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }

    /// Two spellings of one UUID are distinct JSON keys but one development Mac, so decoding
    /// straight into a dictionary kept one entry and dropped the other's checkpoint in silence.
    @Test func aSnapshotNamingOneDevelopmentMacTwiceIsRejected() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: Date())
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let store = try StateStore(rootURL: root)
        try await store.saveSnapshot(EnvironmentsSnapshot(
            environments: [environment],
            slots: slots,
            provisioning: [environment.id: ProvisioningState(stage: .sshPaired, status: .canceled)]
        ))
        let text = String(decoding: try Data(contentsOf: await store.snapshotURL), as: UTF8.self)
        let upper = environment.id.uuid.uuidString.uppercased()
        let lower = environment.id.uuid.uuidString.lowercased()
        #expect(text.contains("\"\(upper)\""))
        let both = text.replacingOccurrences(
            of: "\"\(upper)\" :",
            with: "\"\(lower)\" : {\"schemaVersion\" : 1, \"stage\" : \"sshPaired\", \"issuedEffects\" : 0, \"status\" : {\"notStarted\" : {}}},\n      \"\(upper)\" :"
        )
        try Data(both.utf8).write(to: await store.snapshotURL)
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
    }

    @Test func twoMigrationsFromOneVersionAreReportedNotTrapped() {
        let ambiguous = SnapshotMigrator(current: SchemaVersion(2)!, migrations: [
            SnapshotMigrator.Migration(from: SchemaVersion(1)!) { _ in Data("{\"schemaVersion\":2}".utf8) },
            SnapshotMigrator.Migration(from: SchemaVersion(1)!) { _ in Data("{\"schemaVersion\":2}".utf8) },
        ])
        #expect(throws: StateStoreError.duplicateMigration(from: SchemaVersion(1)!)) {
            try ambiguous.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }
}

// MARK: - Access control lists

/// Grants the current user an explicit entry, the way a restore or a `chmod +a` leaves one.
private func grantExtendedACL(at url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    defer { close(descriptor) }
    try #require(descriptor >= 0)
    var acl: acl_t? = acl_init(1)
    defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
    var entry: acl_entry_t?
    try #require(acl_create_entry(&acl, &entry) == 0)
    try #require(acl_set_tag_type(entry!, ACL_EXTENDED_ALLOW) == 0)
    // The compatibility UUID macOS gives a POSIX user id.
    var qualifier = try #require(UUID(uuidString: String(format: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA%08X", getuid()))).uuid
    try #require(withUnsafePointer(to: &qualifier) { acl_set_qualifier(entry!, UnsafeRawPointer($0)) } == 0)
    var permissions: acl_permset_t?
    try #require(acl_get_permset(entry!, &permissions) == 0)
    try #require(acl_add_perm(permissions!, ACL_READ_DATA) == 0)
    try #require(acl_set_fd(descriptor, acl!) == 0)
}

private func hasExtendedACL(at url: URL) -> Bool {
    let descriptor = open(url.path, O_RDONLY)
    defer { close(descriptor) }
    guard descriptor >= 0, let acl = acl_get_fd(descriptor) else { return false }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
}
