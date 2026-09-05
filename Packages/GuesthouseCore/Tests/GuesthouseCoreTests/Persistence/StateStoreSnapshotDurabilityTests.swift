import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStoreSnapshotDurabilityTests {
    let fixture = FileManager.default.temporaryDirectory
        .appending(path: "StateStoreSnapshotDurability-\(UUID().uuidString)")

    @Test(arguments: [false, true])
    func replacementDuringFinalDirectoryBarrierRefusesSave(replaceDirectory: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "state")
        let detached = fixture.appending(path: "detached")
        let published = root.appending(path: StateStore.snapshotFileName)
        let replacement = Data("restored snapshot fixture".utf8)
        let store = try StateStore(rootURL: root, directoryBarrier: { descriptor, name in
            try StateStore.fullySynchronize(descriptor, name: name)
            if replaceDirectory {
                try FileManager.default.moveItem(at: root, to: detached)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            } else {
                try FileManager.default.moveItem(at: published, to: detached)
            }
            try replacement.write(to: published)
        })
        let expected: StateStoreError = replaceDirectory
            ? .insecureDirectory(reason: "the folder was renamed, removed, or replaced while Guesthouse was using it")
            : .fileUnwritable(name: StateStore.snapshotFileName)
        await #expect(throws: expected) { try await store.saveSnapshot(.empty) }
        let retained = replaceDirectory ? detached.appending(path: StateStore.snapshotFileName) : detached
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: Data(contentsOf: retained)) == .empty)
        #expect(try Data(contentsOf: published) == replacement)
    }
}
