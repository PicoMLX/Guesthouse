import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct StateStoreSnapshotTests {
    @Test func reopenRetainsInventoryAndNeverTouchesGuestFiles() async throws {
        let fixture = try Fixture(), value = try sample()
        defer { fixture.remove() }
        let work = try fixture.storage.location(for: .vms).appending(path: "saved-work")
        let original = Data("unpublished guest work".utf8)
        try original.write(to: work)
        let store = try await fixture.open()
        #expect(try await store.loadSnapshot() == .empty)
        try await store.saveSnapshot(value)
        await store.close()
        let reopened = try await fixture.open()
        #expect(try await reopened.loadSnapshot() == value)
        #expect(try Data(contentsOf: work) == original)
        var info = stat()
        try #require(lstat(fixture.snapshot.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        await reopened.close()
    }

    @Test func secondOwnerIsRefusedUntilFirstCloses() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.open()
        let version = try StateDirectoryAnchor(storage: fixture.storage).verifyCurrent()
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { _ = try await fixture.open() }
        #expect(try StateDirectoryAnchor(storage: fixture.storage).verifyCurrent() == version)
        #expect(try await first.loadSnapshot() == .empty)
        await first.close()
        let second = try await fixture.open()
        #expect(try await second.loadSnapshot() == .empty)
        await #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) { try await first.loadSnapshot() }
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await first.saveSnapshot(.empty) }
        await second.close()
    }

    @Test func droppingOwnerReleasesItsLock() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var store: StateStore? = try await fixture.open()
        weak let observer = store
        store = nil
        #expect(observer == nil)
        let reopened = try await fixture.open()
        await reopened.close()
    }

    @Test(arguments: [false, true])
    func reopeningDoesNotRepairOrRecreateStorage(missing: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if missing { try FileManager.default.removeItem(at: fixture.state) }
        else { try #require(chmod(fixture.state.path, 0o755) == 0) }
        await #expect(throws: StateStoreError.self) { _ = try await fixture.open() }
        var info = stat()
        if missing { #expect(lstat(fixture.state.path, &info) == -1 && errno == ENOENT) }
        else {
            try #require(lstat(fixture.state.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o755)
        }
    }

    @Test func savingRequiresLoadAndReplacesRatherThanTruncates() async throws {
        let fixture = try Fixture(), first = try sample(), second = try sample()
        defer { fixture.remove() }
        let store = try await fixture.open()
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await store.saveSnapshot(first) }
        #expect(try fixture.names().isEmpty)
        _ = try await store.loadSnapshot()
        try await store.saveSnapshot(first)
        let oldBytes = try Data(contentsOf: fixture.snapshot)
        let old = open(fixture.snapshot.path, O_RDONLY | O_CLOEXEC)
        try #require(old >= 0)
        defer { close(old) }
        try await store.saveSnapshot(second)
        #expect(try StateFileIO.readAll(old, from: 0, name: .snapshot) == oldBytes)
        #expect(try await store.loadSnapshot() == second)
        #expect(try fixture.names() == ["environments.json"])
        await store.close()
    }

    @Test(arguments: ["not JSON", "{\"schemaVersion\":99}", "{\"schemaVersion\":1}"])
    func rejectedRecordsArePreservedAcrossLoadsAndSaves(raw: String) async throws {
        let fixture = try Fixture(), bytes = Data(raw.utf8)
        defer { fixture.remove() }
        try fixture.write(bytes)
        let store = try await fixture.open()
        await #expect(throws: StateStoreError.self) { try await store.loadSnapshot() }
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await store.saveSnapshot(.empty) }
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
        #expect(try fixture.names() == ["environments.json"])
        await store.close()
    }

    @Test(arguments: ["write", "file", "directory"])
    func publicationFailuresRequireInspectionAndKeepACompleteSnapshot(stage: String) async throws {
        let fixture = try Fixture(), before = try sample(), after = try sample()
        defer { fixture.remove() }
        let initial = try await fixture.open()
        _ = try await initial.loadSnapshot()
        try await initial.saveSnapshot(before)
        await initial.close()
        let calls = Mutex(0)
        let hooks = StateStoreHooks(write: { fd, bytes in
            calls.withLock { $0 += 1 }
            if stage == "write" {
                try StateFileIO.writeAll(fd, Data(bytes.prefix(8)), name: .snapshot)
                throw StateStoreError.fileUnwritable(name: .snapshot)
            }
            try StateFileIO.writeAll(fd, bytes, name: .snapshot)
        }, synchronize: { fd, name in
            if (stage == "file" && name == .snapshot) || (stage == "directory" && name == .stateDirectory) {
                throw StateStoreError.fileUnwritable(name: name)
            }
            try StateFileIO.fullySynchronize(fd, name: name)
        })
        let store = try await fixture.open(hooks: hooks)
        _ = try await store.loadSnapshot()
        await #expect(throws: StateStoreError.fileUnwritable(name: stage == "directory" ? .stateDirectory : .snapshot)) {
            try await store.saveSnapshot(after)
        }
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await store.saveSnapshot(before) }
        #expect(calls.withLock { $0 } == 1)
        #expect(try fixture.names() == ["environments.json"])
        #expect(try await store.loadSnapshot() == (stage == "directory" ? after : before))
        await store.close()
        let reopened = try await fixture.open()
        _ = try await reopened.loadSnapshot()
        try await reopened.saveSnapshot(after)
        #expect(try await reopened.loadSnapshot() == after)
        await reopened.close()
    }

    @Test func interruptedTemporaryIsPreservedAndBlocksPublication() async throws {
        let fixture = try Fixture(), pending = fixture.state.appending(path: ".environments.json.pending")
        defer { fixture.remove() }
        let evidence = Data("partial earlier save".utf8)
        try evidence.write(to: pending)
        let store = try await fixture.open()
        _ = try await store.loadSnapshot()
        await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) { try await store.saveSnapshot(.empty) }
        #expect(try Data(contentsOf: pending) == evidence)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        await store.close()
    }

    @Test func invalidAndOversizedValuesDoNotReplaceSavedState() async throws {
        let fixture = try Fixture(), good = try sample()
        defer { fixture.remove() }
        let store = try await fixture.open()
        _ = try await store.loadSnapshot()
        try await store.saveSnapshot(good)
        let bytes = try Data(contentsOf: fixture.snapshot)
        var bad = good
        bad.slots = VMSlotInventory()
        await #expect(throws: StateStoreError.inconsistentSnapshot(reason: .slotsDisagree)) { try await store.saveSnapshot(bad) }
        _ = try await store.loadSnapshot()
        bad = good
        bad.environments[0].name = String(repeating: "x", count: StateFileIO.maximumSnapshotBytes)
        await #expect(throws: StateStoreError.unencodable(name: .snapshot)) { try await store.saveSnapshot(bad) }
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
        await store.close()
    }

    private func sample() throws -> EnvironmentsSnapshot {
        let environment = DevelopmentEnvironment(name: "Task Mac")
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        return EnvironmentsSnapshot(environments: [environment], slots: slots, provisioning: [environment.id: .initial])
    }

    private struct Fixture: Sendable {
        let base: URL
        let storage: RuntimeStorage
        var state: URL { base.appending(path: "Guesthouse/state") }
        var snapshot: URL { state.appending(path: "environments.json") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-snapshot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            storage = try RuntimeStorage(root: base.appending(path: "Guesthouse"))
        }
        func open(hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(existingRoot: base.appending(path: "Guesthouse")) }, hooks: hooks)
        }
        func write(_ bytes: Data) throws {
            try bytes.write(to: snapshot)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        }
        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: state.path).sorted() }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
