import Darwin
import Dispatch
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Actual actor composition of the retained #57 snapshot contracts, not just helper tests.
/// Every root is an isolated fixture; never call the default App Support factory here.
@Suite(.timeLimit(.minutes(1))) struct StateStoreSnapshotTests {
    @Test(arguments: [false, true])
    func observedSnapshotDisappearanceNeverBecomesEmptyOrRecreated(observedBySave: Bool) async throws {
        let fixture = try Fixture(), writer = try await fixture.open(), value = try sample()
        try await writer.saveSnapshot(value)
        let reader = try await fixture.open(), store = observedBySave ? writer : reader
        if !observedBySave { #expect(try await store.loadSnapshot() == value) }
        try await requireMissingSnapshotRefusal(store, fixture: fixture)
    }

    @Test(arguments: [false, true])
    func failedSnapshotReadOrOverwriteStillRemembersEvidence(throughSave: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        try fixture.write(Data("corrupt snapshot evidence".utf8))
        if throughSave {
            await #expect(throws: StateStoreError.corruptSnapshot) { try await store.saveSnapshot(.empty) }
        } else {
            await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
        }
        try await requireMissingSnapshotRefusal(store, fixture: fixture)
    }

    @Test func failedVisiblePublicationStillRemembersSnapshot() async throws {
        let fixture = try Fixture()
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { _, _ in
            throw StateStoreError.fileUnwritable(name: .stateDirectory)
        }))
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) {
            try await store.saveSnapshot(.empty)
        }
        try await requireMissingSnapshotRefusal(store, fixture: fixture)
    }

    @Test func deniedSnapshotOpenStillRemembersEvidence() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        try fixture.write(Data("unreadable evidence".utf8))
        try #require(chmod(fixture.snapshot.path, 0) == 0)
        await #expect(throws: StateStoreError.fileUnreadable(name: .snapshot)) { try await store.loadSnapshot() }
        #expect(try fixture.mode(fixture.snapshot) == 0)
        try #require(chmod(fixture.snapshot.path, 0o600) == 0)
        try await requireMissingSnapshotRefusal(store, fixture: fixture)
    }

    private func requireMissingSnapshotRefusal(_ store: StateStore, fixture: Fixture) async throws {
        let evidence = try fixture.bytes(), retained = fixture.state.appending(path: "retained-evidence")
        try #require(rename(fixture.snapshot.path, retained.path) == 0)
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .snapshot)) { try await store.loadSnapshot() }
            await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await store.saveSnapshot(.empty) }
        }
        #expect(try fixture.names() == ["retained-evidence"])
        #expect(try Data(contentsOf: retained) == evidence)
    }

    @Test func openingAndMissingReadDoNotCreateStateFiles() async throws {
        let fixture = try Fixture()
        let barriers = Mutex<[StateStoreError.File]>([])
        let store = try await fixture.open(hooks: StateStoreHooks(preparation: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            barriers.withLock { $0.append(name) }
        }))
        #expect(barriers.withLock { !$0.isEmpty && $0.allSatisfy { $0 == .stateDirectory } })
        #expect(try await store.loadSnapshot() == .empty)
        #expect(try fixture.names().isEmpty)
    }

    @Test func snapshotRoundTripsAcrossReopeningWithExactDatesAndUUIDKeys() async throws {
        let fixture = try Fixture(), value = try sample()
        let store = try await fixture.open()
        try await store.saveSnapshot(value)
        #expect(try await store.loadSnapshot() == value)
        let reopened = try await fixture.open()
        #expect(try await reopened.loadSnapshot() == value)
        let json = try #require(JSONSerialization.jsonObject(with: fixture.bytes()) as? [String: Any])
        let provisioning = try #require(json["provisioning"] as? [String: Any])
        #expect(Set(provisioning.keys) == [value.environments[0].id.uuid.uuidString])
        #expect(json["schemaVersion"] as? Int == 2)
        #expect(try fixture.mode(fixture.state) == 0o700)
        #expect(try fixture.mode(fixture.snapshot) == 0o600)
    }

    // Retains #57's actual-store counter regression under #166's full-range contract.
    @Test(arguments: [
        (UInt64(9_223_372_036_854_775_807), UInt64(9_223_372_036_854_775_808)),
        (9_223_372_036_854_775_808, 9_223_372_036_854_775_809),
        (UInt64.max - 1, UInt64.max),
        (UInt64.max, nil),
    ] as [(UInt64, UInt64?)])
    func highCountersRemainPersistableAcrossReopening(counter: UInt64, next: UInt64?) async throws {
        let fixture = try Fixture()
        var value = try sample()
        let environment = try #require(value.environments.first).id
        value.provisioning[environment] = ProvisioningState(
            stage: .first, status: .awaitingInspection(EffectToken(counter)), issuedEffects: counter
        )
        let store = try await fixture.open()
        try await store.saveSnapshot(value)
        let bytes = try fixture.bytes()
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: bytes) == value)
        let reopened = try await fixture.open()
        let restored = try await reopened.loadSnapshot()
        #expect(restored == value)
        let state = try #require(restored.provisioning[environment])
        #expect(state.issuedEffects == counter)
        #expect(state.status.pendingEffect == EffectToken(counter))
        #expect(state.nextEffectToken?.value == next)
        #expect(try fixture.bytes() == bytes)
        try await reopened.saveSnapshot(restored)
        #expect(try fixture.bytes() == bytes)
        #expect(try fixture.names() == ["environments.json"])
    }

    @MainActor @Test func mainActorCallerDoesNotPerformStorageOrBarrierWork() async throws {
        let fixture = try Fixture()
        let visited = Mutex<Set<String>>([])
        let barrier: StateStoreHooks.Barrier = { fd, name in
            #expect(!Thread.isMainThread)
            try StateFileIO.fullySynchronize(fd, name: name)
            _ = visited.withLock { $0.insert("barrier") }
        }
        let store = try await StateStore.open(storage: {
            #expect(!Thread.isMainThread)
            _ = visited.withLock { $0.insert("factory") }
            return try RuntimeStorage(root: fixture.root)
        }, hooks: StateStoreHooks(preparation: barrier, permission: barrier,
                                  snapshotFile: barrier, directory: barrier))
        try await store.saveSnapshot(.empty)
        #expect(try await store.loadSnapshot() == .empty)
        #expect(visited.withLock { $0 } == ["factory", "barrier"])
    }

    @Test func failedPreparationClosesTheAnchorAndRetainsExistingBytes() async throws {
        let fixture = try Fixture()
        let initial = try await fixture.open()
        try await initial.saveSnapshot(.empty)
        let bytes = try fixture.bytes(), closed = Mutex(0)
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) {
            try await fixture.open(hooks: StateStoreHooks(preparation: { _, _ in
                throw FixtureFailure.opaque
            }, didCloseDirectory: { closed.withLock { $0 += 1 } }))
        }
        #expect(closed.withLock { $0 } == 1)
        #expect(try fixture.bytes() == bytes)
    }

    @Test(arguments: [StorageFailure.protectionDrift, .unsafeStructure, .inspectionFailed])
    func knownFactoryProtectionFailuresRetainRecoveryGuidance(failure: StorageFailure) async {
        let reason: StateStoreError.ProtectionFailure = switch failure {
        case .protectionDrift: .permissions
        case .unsafeStructure: .changed
        default: .unreadable
        }
        await #expect(throws: StateStoreError.insecureDirectory(reason: reason)) {
            try await StateStore.open(storage: { throw failure })
        }
    }

    @Test(arguments: ["environments", "slots", "provisioning", "schemaVersion", #"\u0065nvironments"#])
    func duplicateSnapshotMembersRefuseLoadAndOverwrite(key: String) async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        try await store.saveSnapshot(.empty)
        let encoded = try #require(String(data: fixture.bytes(), encoding: .utf8))
        let bytes = Data((encoded.dropLast() + ",\"" + key + "\":null}").utf8)
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.saveSnapshot(.empty) }
        #expect(try fixture.bytes() == bytes)
        #expect(try fixture.names() == ["environments.json"])
    }

    @Test(arguments: [#"{"name":"first","name":"second"}"#,
                      #"{"slot":{"id":1,"\u0069d":2}}"#,
                      #"{"provisioning":[{"stage":1,"stage":2}]}"#])
    func nestedDuplicateMembersRefuseLoadAndOverwrite(nested: String) async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let encoded = try #require(String(data: JSONEncoder().encode(EnvironmentsSnapshot.empty), encoding: .utf8))
        let bytes = Data((encoded.dropLast() + ",\"extension\":" + nested + "}").utf8)
        #expect(throws: StateStoreError.corruptSnapshot) { try SnapshotMigrator.standard.migrate(bytes) }
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.saveSnapshot(.empty) }
        #expect(try fixture.bytes() == bytes)
    }

    @Test func distinctObjectsMayReuseKeysAndQuotedColonsAreNotMembers() throws {
        let encoded = try #require(String(data: JSONEncoder().encode(EnvironmentsSnapshot.empty), encoding: .utf8))
        let extra = #","extension":[{"name":"a"},{"name":"b","text":"\\\"name\\\":0"}]}"#
        #expect(throws: Never.self) { try SnapshotMigrator.standard.migrate(Data((encoded.dropLast() + extra).utf8)) }
    }

    @Test(arguments: [false, true]) func duplicateMigrationOutputCannotAuthorizeRewrite(nested: Bool) async throws {
        let fixture = try Fixture()
        let encoded = try #require(String(data: JSONEncoder().encode(EnvironmentsSnapshot.empty), encoding: .utf8))
        let extra = nested ? #","extension":{"stage":1,"stage":2}}"# : ",\"environments\":null}"
        let ambiguous = Data((encoded.dropLast() + extra).utf8)
        let previous = SchemaVersion(EnvironmentsSnapshot.currentSchema.rawValue - 1)!
        let migrator = SnapshotMigrator(migrations: [.init(from: previous) { _ in ambiguous }])
        let store = try await fixture.open(migrator: migrator)
        let original = Data("{\"schemaVersion\":\(previous.rawValue)}".utf8)
        try fixture.write(original)
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.saveSnapshot(.empty) }
        #expect(try fixture.bytes() == original)
    }

    @Test func arbitraryFactoryErrorsBecomeClosedFailures() async {
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) {
            try await StateStore.open(storage: { throw FixtureFailure.opaque })
        }
    }

    @Test func releasingTheStoreReleasesItsAnchorExactlyOnce() async throws {
        let fixture = try Fixture(), closed = Mutex(0)
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        weak var weakStore: StateStore?
        do {
            let store = try await fixture.open(hooks: StateStoreHooks(didCloseDirectory: {
                closed.withLock { $0 += 1 }
                continuation.yield(())
                continuation.finish()
            }))
            weakStore = store
            try await store.saveSnapshot(.empty)
        }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(weakStore == nil)
        #expect(closed.withLock { $0 } == 1)
    }

    @Test(arguments: [
        ("{", StateStoreError.corruptSnapshot),
        ("{}", .migrationMissing(from: .unversioned)),
        ("{\"schemaVersion\":1}", .migrationMissing(from: SchemaVersion(1)!)),
        ("{\"schemaVersion\":2}", .corruptSnapshot),
        ("{\"schemaVersion\":99}", .newerSchemaVersion(found: SchemaVersion(99)!, current: SchemaVersion(2)!)),
    ])
    func rejectedSnapshotReadsAndSavesPreserveOriginal(raw: String, failure: StateStoreError) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), bytes = Data(raw.utf8)
        try fixture.write(bytes)
        await #expect(throws: failure) { try await store.loadSnapshot() }
        await #expect(throws: failure) { try await store.saveSnapshot(.empty) }
        #expect(try fixture.bytes() == bytes)
        #expect(try fixture.names() == ["environments.json"])
    }

    @Test func oversizedSavedSnapshotRefusesLoadAndReplacement() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let evidence = Data(repeating: 32, count: 4 * 1024 * 1024 + 1)
        try fixture.write(evidence)
        await #expect(throws: StateStoreError.fileUnreadable(name: .snapshot)) { try await store.loadSnapshot() }
        await #expect(throws: StateStoreError.fileUnreadable(name: .snapshot)) { try await store.saveSnapshot(.empty) }
        #expect(try fixture.bytes() == evidence)
        #expect(try fixture.names() == ["environments.json"])
    }

    @Test func explicitMigrationRunsInMemoryWithoutRewritingSource() async throws {
        let fixture = try Fixture()
        let initial = try await fixture.open()
        try await initial.saveSnapshot(.empty)
        var object = try #require(JSONSerialization.jsonObject(with: fixture.bytes()) as? [String: Any])
        object["schemaVersion"] = nil
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try fixture.write(bytes)
        let migrator = SnapshotMigrator(migrations: [
            .init(from: .unversioned) { try Self.settingVersion(1, in: $0) },
            .init(from: SchemaVersion(1)!) { try Self.settingVersion(2, in: $0) },
        ])
        let store = try await fixture.open(migrator: migrator)
        #expect(try await store.loadSnapshot() == .empty)
        #expect(try fixture.bytes() == bytes)
    }

    @Test func invalidAndUnencodableValuesCannotCreateFiles() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        await #expect(throws: StateStoreError.inconsistentSnapshot(reason: .slotsDisagree)) {
            try await store.saveSnapshot(EnvironmentsSnapshot(environments: [DevelopmentEnvironment(name: "Dev")]))
        }
        let invalidDate = try sample(date: Date(timeIntervalSinceReferenceDate: .infinity))
        await #expect(throws: StateStoreError.unencodable(name: .snapshot)) {
            try await store.saveSnapshot(invalidDate)
        }
        #expect(try fixture.names().isEmpty)
    }

    @Test func permissionBarrierIsRequiredEvenForAnAlreadyRepairedRead() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        try await store.saveSnapshot(.empty)
        try #require(chmod(fixture.snapshot.path, 0o640) == 0)
        let failed = try await fixture.open(hooks: StateStoreHooks(permission: { _, _ in
            throw FixtureFailure.opaque
        }))
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await failed.loadSnapshot() }
        #expect(try fixture.mode(fixture.snapshot) == 0o600)
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await failed.loadSnapshot() }
        #expect(try await store.loadSnapshot() == .empty)
    }

    @Test func fileBarrierFailureDoesNotReplaceTheSavedSnapshot() async throws {
        let fixture = try Fixture(), initial = try await fixture.open()
        try await initial.saveSnapshot(sample())
        let bytes = try fixture.bytes()
        let failed = try await fixture.open(hooks: StateStoreHooks(snapshotFile: { _, _ in throw FixtureFailure.opaque }))
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await failed.saveSnapshot(.empty) }
        #expect(try fixture.bytes() == bytes)
        #expect(try fixture.names().count == 2)
    }

    @Test func failedDirectoryBarrierDoesNotImplyPublicationWasRolledBack() async throws {
        let fixture = try Fixture()
        let failed = try await fixture.open(hooks: StateStoreHooks(directory: { _, _ in throw FixtureFailure.opaque }))
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { try await failed.saveSnapshot(.empty) }
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: fixture.bytes()) == .empty)
        #expect(try fixture.names() == ["environments.json"])
    }

    @Test(arguments: [(false, StateStoreError.fileUnwritable(name: .snapshot)), (true, .insecureDirectory(reason: .changed))])
    func sameInodeReattachmentAtPublicationIsRefused(directory: Bool, failure: StateStoreError) async throws {
        let fixture = try Fixture()
        let target = directory ? fixture.state : fixture.snapshot, detached = fixture.base.appending(path: "detached")
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            let identity = try fixture.identity(target)
            try #require(rename(target.path, detached.path) == 0)
            try #require(rename(detached.path, target.path) == 0)
            try #require(try fixture.identity(target) == identity)
        }))
        await #expect(throws: failure) { try await store.saveSnapshot(.empty) }
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: fixture.bytes()) == .empty)
    }

    @Test func hardLinkedSnapshotIsNeverReadOrReplaced() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        try await store.saveSnapshot(.empty)
        let bytes = try fixture.bytes()
        try #require(link(fixture.snapshot.path, fixture.state.appending(path: "alias").path) == 0)
        await #expect(throws: StateStoreError.insecureDirectory(reason: .multipleLinks)) { try await store.loadSnapshot() }
        await #expect(throws: StateStoreError.insecureDirectory(reason: .multipleLinks)) { try await store.saveSnapshot(.empty) }
        #expect(try fixture.bytes() == bytes)
    }

    @Test func snapshotSymlinkIsRefusedWithoutTouchingItsTarget() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let target = fixture.base.appending(path: "other"), evidence = Data("retained fixture".utf8)
        try evidence.write(to: target)
        try #require(symlink(target.path, fixture.snapshot.path) == 0)
        await #expect(throws: StateStoreError.insecureDirectory(reason: .symbolicLink)) { try await store.loadSnapshot() }
        await #expect(throws: StateStoreError.insecureDirectory(reason: .symbolicLink)) { try await store.saveSnapshot(.empty) }
        #expect(try Data(contentsOf: target) == evidence)
    }

    @Test func explicitlyUnsupportedDecodeKeepsItsTypedFailure() async throws {
        let fixture = try Fixture()
        let future = SchemaVersion(99)!
        let store = try await fixture.open(migrator: SnapshotMigrator(current: future, migrations: []))
        let bytes = Data("{\"schemaVersion\":99}".utf8)
        try fixture.write(bytes)
        await #expect(throws: StateStoreError.unsupportedSnapshotVersion(found: future, current: SchemaVersion(2)!)) {
            try await store.loadSnapshot()
        }
        #expect(try fixture.bytes() == bytes)
    }

    @Test(arguments: [false, true])
    func independentStoresCannotOverlapPublication(afterRename: Bool) async throws {
        let fixture = try Fixture(), replacement = try sample()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        let barrier: StateStoreHooks.Barrier = { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            continuation.yield(())
            // This bounded fixture wait is on the store's dedicated native-I/O executor,
            // never a cooperative task executor or MainActor.
            try #require(release.wait(timeout: .now() + 10) == .success)
        }
        let first = try await fixture.open(hooks: afterRename
            ? StateStoreHooks(directory: barrier) : StateStoreHooks(snapshotFile: barrier))
        let second = try await fixture.open()
        let pending = Task {
            defer { continuation.finish() }
            try await first.saveSnapshot(.empty)
        }
        defer { release.signal() }
        var iterator = events.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        let names = try fixture.names()
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try await second.saveSnapshot(replacement)
        }
        #expect(try fixture.names() == names)
        release.signal()
        try await pending.value
        #expect(try await second.loadSnapshot() == .empty)
        // An explicit subsequent transaction can acquire the released ownership.
        try await second.saveSnapshot(replacement)
        #expect(try await first.loadSnapshot() == replacement)
    }

    @Test func actorSerializesCompletePublicationsAcrossConcurrentCallers() async throws {
        let fixture = try Fixture(), completed = Mutex(0)
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            completed.withLock { $0 += 1 }
        }))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { try await store.saveSnapshot(.empty) } }
            try await group.waitForAll()
        }
        #expect(completed.withLock { $0 } == 20)
        #expect(try await store.loadSnapshot() == .empty)
        #expect(try fixture.names() == ["environments.json"])
    }

    @Test func cancellationDoesNotReportFailureForACompletedSave() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                withUnsafeCurrentTask { $0?.cancel() }
                try await store.saveSnapshot(.empty)
            }
            try await group.waitForAll()
        }
        #expect(try await store.loadSnapshot() == .empty)
    }

    private enum FixtureFailure: Error { case opaque }

    private func sample(date: Date = Date(timeIntervalSinceReferenceDate: 800_000_000.123456789)) throws -> EnvironmentsSnapshot {
        let environment = DevelopmentEnvironment(name: "Dev", createdAt: date)
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        return EnvironmentsSnapshot(environments: [environment], slots: slots, provisioning: [environment.id: .initial])
    }

    private static func settingVersion(_ version: Int, in data: Data) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = version
        return try JSONSerialization.data(withJSONObject: object)
    }

    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var snapshot: URL { state.appending(path: "environments.json") }

        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-store-snapshots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }

        func open(migrator: SnapshotMigrator = .standard, hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(root: self.root) }, migrator: migrator, hooks: hooks)
        }
        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: state.path) }
        func bytes() throws -> Data { try Data(contentsOf: snapshot) }
        func write(_ bytes: Data) throws {
            try bytes.write(to: snapshot)
            try #require(chmod(snapshot.path, 0o600) == 0)
        }
        func mode(_ path: URL) throws -> mode_t {
            var info = stat()
            try #require(lstat(path.path, &info) == 0)
            return info.st_mode & 0o7777
        }
        func identity(_ path: URL) throws -> StateFileIdentity {
            var info = stat()
            try #require(lstat(path.path, &info) == 0)
            return StateFileIdentity(info)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
