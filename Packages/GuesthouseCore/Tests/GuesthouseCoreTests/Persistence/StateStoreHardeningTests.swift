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
        var json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(json.contains("\"format\":1"))
        json = json.replacingOccurrences(of: "\"format\":1", with: "\"format\":2")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8)) }
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
