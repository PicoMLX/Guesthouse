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
        let skipping = SnapshotMigrator(current: SchemaVersion(3), migrations: [
            SnapshotMigrator.Migration(from: SchemaVersion(1)) { _ in Data("{\"schemaVersion\":3}".utf8) },
        ])
        #expect(throws: StateStoreError.migrationProducedWrongVersion(from: SchemaVersion(1), produced: SchemaVersion(3))) {
            try skipping.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }

    @Test func everyStoreErrorIsActionable() {
        let errors: [StateStoreError] = [
            .insecureDirectory(reason: "x"), .corruptSnapshot, .inconsistentSnapshot(reason: "x"), .corruptJournal(line: 1),
            .inconsistentRecord(OperationID()), .newerSchemaVersion(found: SchemaVersion(2), current: SchemaVersion(1)),
            .migrationMissing(from: SchemaVersion(1)), .migrationProducedWrongVersion(from: SchemaVersion(1), produced: SchemaVersion(3)), .fileUnwritable(name: "x"),
        ]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
            #expect(error.errorDescription == error.userMessage)
        }
    }
}
