import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStoreRecoveryTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "StateStoreRecovery-\(UUID().uuidString)")

    @Test(arguments: [false, true], [false, true])
    func existingAncestryIsResynchronizedBeforeAcceptance(throughSymlink: Bool, existingLeaf: Bool) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appending(path: "actual/a/b")
        // These visible entries model a process dying after mkdir but before its barriers.
        try FileManager.default.createDirectory(at: existingLeaf ? actual : actual.deletingLastPathComponent(), withIntermediateDirectories: true)
        var location = actual
        if throughSymlink {
            let alias = root.appending(path: "alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appending(path: "actual"))
            location = alias.appending(path: "a/b")
        }
        var synchronized: [String] = []
        let descriptor = try StateStore.prepareDirectory(location) { synchronized.append($0.path) }
        defer { close(descriptor) }
        let physicalRoot = try #require(realpath(root.path, nil))
        defer { free(physicalRoot) }
        let expected = ["", "/actual", "/actual/a"].map { String(cString: physicalRoot) + $0 }
        #expect(synchronized.filter { expected.contains($0) } == expected)
        #expect(synchronized.contains(root.path))
        #expect(synchronized.first == "/")
        #expect(Set(synchronized).count == synchronized.count)
    }

    @Test func failedAncestryBarrierRefusesAcceptanceAndRetryResynchronizes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appending(path: "a/b")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let journal = actual.appending(path: StateStore.journalFileName)
        let evidence = Data("existing operation evidence".utf8)
        try evidence.write(to: journal)
        let failedParent = root.appending(path: "a").resolvingSymlinksInPath().path
        let failure = StateStoreError.fileUnwritable(name: "a")
        #expect(throws: failure) {
            let descriptor = try StateStore.prepareDirectory(actual) { parent in
                if parent.path == failedParent { throw failure }
            }
            close(descriptor)
        }
        #expect(try Data(contentsOf: journal) == evidence)
        var synchronized: [String] = []
        let descriptor = try StateStore.prepareDirectory(actual) { synchronized.append($0.path) }
        defer { close(descriptor) }
        #expect(synchronized.first == "/")
        #expect(synchronized.last == failedParent)
        #expect(try Data(contentsOf: journal) == evidence)
    }

    @Test(arguments: [false, true])
    func newerOuterSnapshotCannotReplaceSavedState(decoded: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StateStore(rootURL: root)
        try await store.saveSnapshot(.empty)
        let snapshotURL = await store.snapshotURL
        let original = try Data(contentsOf: snapshotURL)
        let staleTemporary = root.appending(path: StateStore.tempPrefix + "preserved")
        try Data("untouched".utf8).write(to: staleTemporary)
        let future: EnvironmentsSnapshot
        if decoded {
            let raw = Data("""
            {"schemaVersion":99,"environments":[],"provisioning":{},"slots":{"slots":[]},"futureField":"must not be discarded on save"}
            """.utf8)
            future = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: raw)
        } else {
            future = EnvironmentsSnapshot(schemaVersion: SchemaVersion(99)!)
        }
        await #expect(throws: StateStoreError.newerSchemaVersion(found: SchemaVersion(99)!, current: .current)) {
            try await store.saveSnapshot(future)
        }
        #expect(try Data(contentsOf: snapshotURL) == original)
        #expect(FileManager.default.fileExists(atPath: staleTemporary.path))
    }

    @Test func anOlderOuterSnapshotMustBeMigratedBeforeSaving() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StateStore(rootURL: root)
        try await store.saveSnapshot(.empty)
        let snapshotURL = await store.snapshotURL
        let original = try Data(contentsOf: snapshotURL)
        await #expect(throws: StateStoreError.inconsistentSnapshot(reason: "snapshot must be migrated to the current schema version before saving")) {
            try await store.saveSnapshot(EnvironmentsSnapshot(schemaVersion: .unversioned))
        }
        #expect(try Data(contentsOf: snapshotURL) == original)
    }

    @Test(arguments: [0, -1])
    func anExplicitNonpositiveSnapshotVersionIsCorruption(version: Int) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try StateStore(rootURL: root)
        let snapshotURL = await store.snapshotURL
        let raw = Data("""
        {"schemaVersion":\(version),"environments":[],"provisioning":{},"slots":{"slots":[]}}
        """.utf8)
        try raw.write(to: snapshotURL)
        await #expect(throws: StateStoreError.corruptSnapshot) { try await store.loadSnapshot() }
        #expect(try Data(contentsOf: snapshotURL) == raw)
    }
}
