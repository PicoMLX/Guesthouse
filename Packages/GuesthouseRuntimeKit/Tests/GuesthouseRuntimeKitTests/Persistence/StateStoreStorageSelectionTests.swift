import Darwin
import Dispatch
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct StateStoreStorageSelectionTests {
    @Test(arguments: [false, true])
    func firstSelectionAndJournalAppendShareOwnership(journalFirst: Bool) async throws {
        let fixture = try Fixture(), value = try selected()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        let barrier: StateStoreHooks.Barrier = { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            continuation.yield(())
            // Only the dedicated native-I/O executor blocks, never an async executor.
            try #require(release.wait(timeout: .now() + 10) == .success)
        }
        let first = try await fixture.open(hooks: journalFirst
            ? StateStoreHooks(journalFile: barrier) : StateStoreHooks(snapshotFile: barrier))
        let second = try await fixture.open()
        let pending = Task {
            defer { continuation.finish() }
            if journalFirst { _ = try await first.begin(.startEnvironment, for: EnvironmentID()) }
            else { try await first.saveSnapshot(value) }
        }
        defer { release.signal() }
        var iterator = events.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        let names = try fixture.names()
        if journalFirst {
            await #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
                try await second.saveSnapshot(value)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        } else {
            await #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                try await second.begin(.startEnvironment, for: EnvironmentID())
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.journal.path))
        }
        #expect(try fixture.names() == names)
        release.signal()
        try await pending.value
        if journalFirst {
            await #expect(throws: StateStoreError.storageSelectionChanged) { try await second.saveSnapshot(value) }
        } else {
            #expect(try await second.loadSnapshot() == value)
            _ = try await second.begin(.startEnvironment, for: EnvironmentID())
            #expect(try await second.replay().records.count == 1)
        }
    }

    @Test func originalSelectionSurvivesSaveReopenAndReadOnlyInspection() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), value = try selected()
        try await store.saveSnapshot(value)
        let reopened = try await fixture.open()
        #expect(try await reopened.loadSnapshot() == value)
        #expect(try fixture.inspect() == value)
        let bytes = try fixture.bytes()
        try await reopened.saveSnapshot(value)
        #expect(try fixture.bytes() == bytes)
    }

    @Test(arguments: [false, true]) func ordinarySavesCannotReplaceOrEraseSelection(erase: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), original = try selected()
        try await store.saveSnapshot(original)
        let bytes = try fixture.bytes()
        var replacement = EnvironmentsSnapshot.empty
        if !erase { replacement = try selected() }
        await #expect(throws: StateStoreError.storageSelectionChanged) { try await store.saveSnapshot(replacement) }
        #expect(try fixture.bytes() == bytes)
        #expect(try fixture.inspect() == original)
        #expect(try fixture.names() == ["environments.json"])
    }

    @Test func savedEnvironmentsWithoutABindingCannotAcquireANewObservedIdentity() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let environment = DevelopmentEnvironment(name: "Preserve unknown placement")
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        try await store.saveSnapshot(EnvironmentsSnapshot(environments: [environment], slots: slots))
        let bytes = try fixture.bytes(), replacement = try selected()
        await #expect(throws: StateStoreError.storageSelectionChanged) { try await store.saveSnapshot(replacement) }
        #expect(try fixture.bytes() == bytes)
    }

    @Test func emptyIntermediateSavesCannotEraseUnknownPlacement() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let environment = DevelopmentEnvironment(name: "Retain unknown placement")
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let original = EnvironmentsSnapshot(environments: [environment], slots: slots)
        try await store.saveSnapshot(original)
        let reopened = try await fixture.open()
        var recaptured = try selected()
        recaptured.environments = original.environments
        recaptured.slots = original.slots
        let bytes = try fixture.bytes(), names = try fixture.names()
        for owner in [store, reopened] {
            for _ in 0..<2 {
                await #expect(throws: StateStoreError.storageSelectionChanged) {
                    try await owner.saveSnapshot(.empty)
                }
                await #expect(throws: StateStoreError.storageSelectionChanged) {
                    try await owner.saveSnapshot(recaptured)
                }
                #expect(try fixture.bytes() == bytes)
                #expect(try fixture.names() == names)
                #expect(try fixture.inspect() == original)
            }
            // Preserving unselected, nonempty work remains an ordinary save, not a reset.
            try await owner.saveSnapshot(original)
            #expect(try await owner.loadSnapshot() == original)
        }
    }

    @Test func genuinelyEmptyUnselectedStateCanStillAcquireItsFirstSelection() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), value = try selected()
        try await store.saveSnapshot(.empty)
        let reopened = try await fixture.open()
        try await reopened.saveSnapshot(value)
        #expect(try fixture.inspect() == value)
    }

    @Test(arguments: [false, true]) func journalHistoryBlocksFirstSelectionEvenWithoutASnapshot(torn: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), value = try selected()
        if torn {
            try Data("{\"format\":".utf8).write(to: fixture.journal)
            try #require(chmod(fixture.journal.path, 0o600) == 0)
        } else { _ = try await store.begin(.startEnvironment, for: EnvironmentID()) }
        let bytes = try Data(contentsOf: fixture.journal)
        await #expect(throws: StateStoreError.storageSelectionChanged) { try await store.saveSnapshot(value) }
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        #expect(try Data(contentsOf: fixture.journal) == bytes)
    }

    @Test func retainedSelectionAllowsLaterJournaledWorkWithoutRecapture() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), value = try selected()
        try await store.saveSnapshot(value)
        let operation = try await store.begin(.startEnvironment, for: EnvironmentID())
        try await store.saveSnapshot(value)
        #expect(try await store.replay().inFlight[operation] != nil)
        #expect(try fixture.inspect().storageSelection == value.storageSelection)
    }

    @Test(arguments: [false, true])
    func peerJournalEvidencePreventsFirstSelectionAfterDisappearance(replace: Bool) async throws {
        let fixture = try Fixture(), first = try await fixture.open(), peer = try await fixture.open()
        let value = try selected()
        _ = try await first.begin(.startEnvironment, for: EnvironmentID())
        let bytes = try Data(contentsOf: fixture.journal), detached = fixture.state.appending(path: "retained")
        try #require(rename(fixture.journal.path, detached.path) == 0)
        if replace {
            try Data().write(to: fixture.journal)
            try #require(chmod(fixture.journal.path, 0o600) == 0)
        }
        let names = try fixture.names().sorted()
        for owner in [peer, first] {
            for _ in 0..<2 {
                await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                    try await owner.saveSnapshot(value)
                }
                #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
                #expect(try fixture.names().sorted() == names)
                #expect(try Data(contentsOf: detached) == bytes)
            }
        }
        if replace { #expect(try Data(contentsOf: fixture.journal).isEmpty) }
        else { #expect(!FileManager.default.fileExists(atPath: fixture.journal.path)) }
    }

    @Test func failedFinalBarrierPreservesVisibleSelectionAndReportsFailure() async throws {
        let fixture = try Fixture(), value = try selected()
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { _, _ in throw Failure.barrier }))
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { try await store.saveSnapshot(value) }
        // Visibility is not a durability pass, but the next inspection must not discard it.
        #expect(try fixture.inspect() == value)
        let reopened = try await fixture.open(), replacement = try selected()
        await #expect(throws: StateStoreError.storageSelectionChanged) { try await reopened.saveSnapshot(replacement) }
        #expect(try fixture.inspect() == value)
    }

    @Test func invalidSelectionSnapshotNeverInspectsOrRepairsTheJournal() async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let evidence = Data("retained journal evidence".utf8)
        try evidence.write(to: fixture.journal)
        try #require(chmod(fixture.journal.path, 0o640) == 0)
        var value = try selected()
        let environment = DevelopmentEnvironment(name: "Invalid date", createdAt: Date(timeIntervalSinceReferenceDate: .infinity))
        try value.slots.reserve(environment.id)
        value.environments = [environment]
        await #expect(throws: StateStoreError.unencodable(name: .snapshot)) { try await store.saveSnapshot(value) }
        var info = stat()
        try #require(lstat(fixture.journal.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o640)
        #expect(try Data(contentsOf: fixture.journal) == evidence)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
    }

    @Test func formatTwoStateIsPreservedWithoutInventingItsOriginalVolume() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), value = try selected()
        let bytes = Data("{\"schemaVersion\":2,\"retained\":\"fixture\"}".utf8)
        try bytes.write(to: fixture.snapshot)
        try #require(chmod(fixture.snapshot.path, 0o600) == 0)
        await #expect(throws: StateStoreError.migrationMissing(from: SchemaVersion(2)!)) { try await store.saveSnapshot(value) }
        #expect(throws: StateStoreError.migrationMissing(from: SchemaVersion(2)!)) { try fixture.inspect() }
        #expect(try fixture.bytes() == bytes)
    }

    private enum Failure: Error { case barrier }
    private func selected() throws -> EnvironmentsSnapshot {
        EnvironmentsSnapshot(storageSelection: try #require(HostStorageSelection(volumeID: UUID())))
    }
    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var snapshot: URL { state.appending(path: "environments.json") }
        var journal: URL { state.appending(path: "journal.ndjson") }
        init() throws {
            var template = Array("/private/tmp/guesthouse-storage-selection-XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else { throw StorageFailure.inspectionFailed }
            base = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func open(hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(root: self.root) }, hooks: hooks)
        }
        func inspect() throws -> EnvironmentsSnapshot {
            try StateStore.inspectSnapshot(storage: { try RuntimeStorage.existing(root: self.root) })
        }
        func bytes() throws -> Data { try Data(contentsOf: snapshot) }
        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: state.path) }
    }
}
