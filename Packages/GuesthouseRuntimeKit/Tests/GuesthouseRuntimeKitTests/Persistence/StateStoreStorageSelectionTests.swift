import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct StateStoreStorageSelectionTests {
    @Test func explicitSelectionSurvivesReopenAndCannotBeReplacedOrCleared() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try await fixture.open()
        let initial = try await store.selectStorageVolume()
        #expect(initial.storageSelection?.volumeID == (try SystemStorageProbe.identifyVolume(atExistingDirectory: fixture.vms)))
        let bytes = try Data(contentsOf: fixture.snapshot)
        #expect(try await store.selectStorageVolume() == initial)
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
        await store.close()
        let reopened = try await fixture.open()
        #expect(try await reopened.loadSnapshot() == initial)
        for selection in [nil, HostStorageSelection(volumeID: UUID())] {
            var changed = initial
            changed.storageSelection = selection
            _ = try await reopened.loadSnapshot()
            await #expect(throws: StateStoreError.storageSelectionChanged) { try await reopened.saveSnapshot(changed) }
            #expect(try Data(contentsOf: fixture.snapshot) == bytes)
        }
        _ = try await reopened.loadSnapshot()
        try await reopened.saveSnapshot(initial)
        await reopened.close()
    }

    @Test func ordinarySaveCannotEstablishSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try await fixture.open()
        _ = try await store.loadSnapshot()
        await #expect(throws: StateStoreError.storageSelectionChanged) {
            try await store.saveSnapshot(EnvironmentsSnapshot(storageSelection: HostStorageSelection(volumeID: UUID())))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        await store.close()
    }

    @Test(arguments: ["inventory", "journal", "torn", "disk", "corrupt", "unsupported"])
    func evidenceOfExistingWorkBlocksFirstSelectionWithoutChangingFiles(evidence: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try await fixture.open()
        _ = try await store.loadSnapshot()
        if evidence == "inventory" {
            let environment = DevelopmentEnvironment(name: "Unpublished work")
            var slots = VMSlotInventory()
            try slots.reserve(environment.id)
            try await store.saveSnapshot(EnvironmentsSnapshot(environments: [environment], slots: slots))
        }
        if evidence == "journal" {
            _ = try await store.replay()
            _ = try await store.begin(.startEnvironment, for: EnvironmentID())
        }
        if evidence == "disk" { try Data("saved work".utf8).write(to: fixture.vms.appending(path: "disk")) }
        if evidence == "torn" { try fixture.write(Data("{".utf8), to: fixture.journal) }
        if evidence == "corrupt" { try fixture.write(Data("broken".utf8), to: fixture.snapshot) }
        if evidence == "unsupported" { try fixture.write(Data(#"{"schemaVersion":99}"#.utf8), to: fixture.snapshot) }
        let before = try fixture.contents()
        await #expect(throws: StateStoreError.self) { try await store.selectStorageVolume() }
        #expect(try fixture.contents() == before)
        await store.close()
    }

    @Test(arguments: [2, 3]) func oldSnapshotLoadsWithoutPublicationOrIdentityInference(version: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = EnvironmentsSnapshot(storageSelection: version == 3 ? HostStorageSelection(volumeID: UUID()) : nil)
        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let original = Data(json.replacingOccurrences(of: "\"schemaVersion\":4", with: "\"schemaVersion\":\(version)").utf8)
        try fixture.write(original, to: fixture.snapshot)
        let store = try await fixture.open()
        #expect(try await store.loadSnapshot() == expected)
        #expect(try Data(contentsOf: fixture.snapshot) == original)
        await store.close()
    }

    private struct Fixture: Sendable {
        let base: URL
        let storage: RuntimeStorage
        var root: URL { base.appending(path: "Guesthouse") }
        var vms: URL { root.appending(path: "vms") }
        var snapshot: URL { root.appending(path: "state/environments.json") }
        var journal: URL { root.appending(path: "state/journal.ndjson") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-selection-\(UUID())")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            storage = try RuntimeStorage(root: base.appending(path: "Guesthouse"))
        }
        func open() async throws -> StateStore { try await StateStore.open(storage: { try RuntimeStorage(existingRoot: root) }) }
        func write(_ bytes: Data, to url: URL) throws {
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func contents() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for folder in [root.appending(path: "state"), vms] {
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    result[file.path] = try Data(contentsOf: file)
                }
            }
            return result
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
