import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct RuntimeStateLoaderTests {
    @Test func loadsOnceRetainsOwnershipAndKeepsUnfinishedOperations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try await fixture.open(), environment = DevelopmentEnvironment(name: "Saved task")
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let snapshot = EnvironmentsSnapshot(environments: [environment], slots: slots)
        _ = try await store.loadSnapshot()
        try await store.saveSnapshot(snapshot)
        _ = try await store.replay()
        let id = try await store.begin(.startEnvironment, for: environment.id)
        await store.close()
        let calls = Mutex(0)
        let loader = RuntimeStateLoader(open: { () async throws(StateStoreError) -> StateStore in
            calls.withLock { $0 += 1 }
            return try await fixture.open()
        })
        #expect(loader.status == .loading)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { await loader.load() } }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(loader.status == .loaded)
        let loaded = try #require(loader.loadedState)
        #expect(loaded.snapshot == snapshot)
        #expect(loaded.journal.inFlight[id]?.environmentID == environment.id)
        #expect(loaded.journal.inFlight[id]?.outcome == .started)
        await #expect(throws: StateStoreError.fileUnwritable(name: .stateDirectory)) { try await fixture.open() }
        // Loading retains saved facts; it never claims a reconciled/running development Mac.
        #expect(loader.status.recoveryMessage.contains("inspection"))
        await loaded.store.close()
    }

    @Test func statusStaysResponsiveWhileOneLoadIsPending() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); resume.finish() }
        let loader = RuntimeStateLoader(open: { () async throws(StateStoreError) -> StateStore in
            signal.yield(())
            for await _ in release { break }
            return try await fixture.open()
        })
        let task = Task { await loader.load() }
        for await _ in entered { break }
        await loader.load() // Must return without launching another filesystem operation.
        #expect(loader.status == .loading)
        #expect(loader.loadedState == nil)
        resume.yield(())
        await task.value
        #expect(loader.status == .loaded)
        await loader.loadedState?.store.close()
    }

    @Test(arguments: ["snapshot", "journal", "unsupported", "tail"])
    func failedOrIncompleteRecoveryPreservesEvidence(kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.root.appending(path: kind == "snapshot" ? "state/environments.json" : "state/journal.ndjson")
        let bytes = Data((kind == "unsupported" ? "{\"format\":99}\n" : kind == "tail" ? "{" : "broken").utf8)
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let loader = RuntimeStateLoader(open: { () async throws(StateStoreError) -> StateStore in try await fixture.open() })
        await loader.load()
        #expect(loader.status == (kind == "unsupported" ? .incompatible : .repairRequired))
        #expect(try Data(contentsOf: path) == bytes)
        if kind == "tail" {
            #expect(loader.loadedState?.journal.truncatedTail == true)
            await loader.loadedState?.store.close()
        } else {
            #expect(loader.loadedState == nil)
            // A failed partial load releases its lock, but never fabricates an empty inventory.
            let reopened = try await fixture.open()
            await reopened.close()
        }
    }

    @Test func missingLayoutIsNotCreatedOrRetriedAndVersionsStillRespond() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "guesthouse-missing-\(UUID())")
        let loader = RuntimeStateLoader(open: { () async throws(StateStoreError) -> StateStore in
            try await StateStore.open(storage: { try RuntimeStorage(existingRoot: root) })
        })
        await loader.load()
        await loader.load()
        #expect(loader.status == .unavailable)
        #expect(loader.loadedState == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let version = RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1")
        let reply = NativeRuntimeRequestHandler.queryReply(.runtimeVersion, version: version, savedState: loader.status)
        guard case .runtimeVersion(let info) = reply else { Issue.record("Version query did not reply"); return }
        #expect(info.savedState == .unavailable)
        #expect(!info.savedState!.recoveryMessage.isEmpty)
        let mutation = NativeRuntimeRequestHandler.queryReply(.startEnvironment(EnvironmentID(), .init()),
                                                              version: version, savedState: .loaded)
        guard case .failed(_, .invalidRequest(.unsupportedOperation)) = mutation else {
            Issue.record("Metadata loading authorized an unsupported mutation"); return
        }
    }

    private struct Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-startup-\(UUID())")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            _ = try RuntimeStorage(root: root)
        }
        func open() async throws(StateStoreError) -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(existingRoot: root) })
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
