import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStoreTests {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "StateStoreTests-\(UUID().uuidString)")
    }

    func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func sampleSnapshot() throws -> EnvironmentsSnapshot {
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        return EnvironmentsSnapshot(
            environments: [environment],
            slots: slots,
            provisioning: [environment.id: ProvisioningState(stage: .sshPaired, status: .canceled)]
        )
    }

    @Test func directoryAndFilesAreRestricted() async throws {
        let store = try StateStore(rootURL: root)
        try await store.saveSnapshot(sampleSnapshot())
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(await store.snapshotURL) == 0o600)
        #expect(try permissions(await store.journalURL) == 0o600)
    }

    @Test func symlinkedRootIsRefused() throws {
        let real = root.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: StateStoreError.insecureDirectory(reason: "symbolic link")) {
            try StateStore(rootURL: link)
        }
    }

    @Test func snapshotRoundTripsAndKeysProvisioningByUUID() async throws {
        let store = try StateStore(rootURL: root)
        let snapshot = try sampleSnapshot()
        try await store.saveSnapshot(snapshot)
        let loaded = try await store.loadSnapshot()
        #expect(loaded == snapshot)

        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: await store.snapshotURL)) as? [String: Any])
        let provisioning = try #require(json["provisioning"] as? [String: Any])
        #expect(provisioning.keys.first == snapshot.environments[0].id.uuid.uuidString)
        #expect(json["schemaVersion"] as? Int == SchemaVersion.current.rawValue)
    }

    @Test func missingSnapshotLoadsEmpty() async throws {
        let store = try StateStore(rootURL: root)
        #expect(try await store.loadSnapshot() == .empty)
    }

    @Test func staleTempFileFromACrashIsIgnoredAndCleanedUp() async throws {
        let store = try StateStore(rootURL: root)
        let snapshot = try sampleSnapshot()
        try await store.saveSnapshot(snapshot)
        let stale = root.appending(path: StateStore.tempPrefix + "crashed")
        try Data("{ partial".utf8).write(to: stale)

        #expect(try await store.loadSnapshot() == snapshot)
        try await store.saveSnapshot(.empty)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix(StateStore.tempPrefix) })
        #expect(try await store.loadSnapshot() == .empty)
    }

    @Test func beginReturnsOnlyAfterTheStartedRecordIsDurable() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        let replay = try await store.replay()
        #expect(replay.inFlight[id]?.outcome == .started)
        #expect(replay.inFlight[id]?.environmentID == environment)
        #expect(replay.truncatedTail == false)
    }

    @Test func replayTracksInFlightOperations() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let done = try await store.begin(.startEnvironment, for: environment, at: now)
        try await store.append(JournalRecord(id: done, environmentID: environment, operation: .startEnvironment, timestamp: now, outcome: .checkpoint(.runtimeReady)))
        try await store.append(JournalRecord(id: done, environmentID: environment, operation: .startEnvironment, timestamp: now, outcome: .completed))
        let failed = try await store.begin(.importXcode, for: environment, at: now)
        try await store.append(JournalRecord(id: failed, environmentID: environment, operation: .importXcode, timestamp: now, outcome: .failed(.runtimeMissing)))
        let lost = try await store.begin(.stopEnvironment, for: environment, at: now)
        try await store.append(JournalRecord(id: lost, environmentID: environment, operation: .stopEnvironment, timestamp: now, outcome: .unknown))

        let replay = try await store.replay()
        #expect(replay.records.count == 7)
        #expect(Set(replay.inFlight.keys) == [lost])
        #expect(replay.inFlight[lost]?.outcome == .unknown)
    }

    @Test func truncatedLastLineIsToleratedAndReported() async throws {
        let store = try StateStore(rootURL: root)
        let environment = EnvironmentID()
        let id = try await store.begin(.startEnvironment, for: environment)
        let handle = try FileHandle(forWritingTo: await store.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"half-written".utf8))
        try handle.close()

        let replay = try await store.replay()
        #expect(replay.truncatedTail)
        #expect(replay.records.count == 1)
        #expect(replay.inFlight[id] != nil)
    }

    @Test func corruptMiddleLineIsRejected() async throws {
        let store = try StateStore(rootURL: root)
        _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        let handle = try FileHandle(forWritingTo: await store.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        // Nothing is appended onto a damaged journal; the damage is reported instead.
        await #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try await store.begin(.stopEnvironment, for: EnvironmentID())
        }
        await #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try await store.replay()
        }
    }

    @Test func unversionedSnapshotIsMigratedFromZero() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = """
        {"environments":[],"provisioning":{},"slots":{"slots":[]}}
        """
        try Data(legacy.utf8).write(to: root.appending(path: StateStore.snapshotFileName))
        let store = try StateStore(rootURL: root)
        let loaded = try await store.loadSnapshot()
        #expect(loaded.schemaVersion == .current)
        #expect(loaded == .empty)
    }

    @Test func newerSnapshotIsRefused() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let future = """
        {"schemaVersion":99,"environments":[],"provisioning":{},"slots":{"slots":[]}}
        """
        try Data(future.utf8).write(to: root.appending(path: StateStore.snapshotFileName))
        let store = try StateStore(rootURL: root)
        await #expect(throws: StateStoreError.newerSchemaVersion(found: SchemaVersion(99), current: .current)) {
            try await store.loadSnapshot()
        }
    }

    @Test func everyOperationKeepsItsDetailThroughTheJournal() async throws {
        let store = try StateStore(rootURL: root)
        var expected: [JournalOperation] = []
        for operation in JournalOperation.allCases {
            let environment = EnvironmentID()
            let id = try await store.begin(operation, for: environment)
            try await store.append(JournalRecord(id: id, environmentID: environment, operation: operation, timestamp: Date(), outcome: .completed))
            expected.append(operation)
        }
        let recorded = try await store.replay().records.filter { $0.outcome == .started }.map(\.operation)
        #expect(recorded == expected)
        #expect(recorded.contains(.provision(stage: .sshPaired)))
        #expect(recorded.contains(.repair(kind: .credentials)))
    }

    @Test func migrationsRunInSequenceAndMissingStepFails() throws {
        let v2 = SnapshotMigrator(current: SchemaVersion(2), migrations: [
            .init(from: SchemaVersion(0)) { data in
                var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                object["schemaVersion"] = 1
                return try JSONSerialization.data(withJSONObject: object)
            },
            .init(from: SchemaVersion(1)) { data in
                var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                object["schemaVersion"] = 2
                object["migrated"] = true
                return try JSONSerialization.data(withJSONObject: object)
            },
        ])
        let (data, from) = try v2.migrate(Data("{}".utf8))
        #expect(from == SchemaVersion(0))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["migrated"] as? Bool == true)

        let gap = SnapshotMigrator(current: SchemaVersion(3), migrations: [])
        #expect(throws: StateStoreError.migrationMissing(from: SchemaVersion(1))) {
            try gap.migrate(Data("{\"schemaVersion\":1}".utf8))
        }
    }
}
