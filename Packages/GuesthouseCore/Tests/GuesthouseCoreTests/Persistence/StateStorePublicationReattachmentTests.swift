import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StateStorePublicationReattachmentTests {
    let fixture = FileManager.default.temporaryDirectory
        .appending(path: "StateStorePublicationReattachment-\(UUID().uuidString)")

    @Test(arguments: [false, true], [false, true])
    func sameInodeReattachmentDuringPublicationIsRefused(snapshot: Bool, rootReattached: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "state")
        let name = snapshot ? StateStore.snapshotFileName : StateStore.journalFileName
        let store = try StateStore(rootURL: root, directoryBarrier: { descriptor, label in
            try StateStore.fullySynchronize(descriptor, name: label)
            let target = rootReattached ? root : root.appending(path: name)
            try Self.reattachWithoutSynchronizing(target)
        })
        let cause: StateStoreError = rootReattached
            ? .insecureDirectory(reason: "the folder was renamed, removed, or replaced while Guesthouse was using it")
            : .fileUnwritable(name: name)
        if snapshot {
            await #expect(throws: cause) { try await store.saveSnapshot(.empty) }
        } else {
            await #expect(throws: StateStoreError.journalWriteUncertain(cause: cause)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
        }
        #expect(await store.directorySynchronizations == 1)
        let evidence = try Data(contentsOf: root.appending(path: name))
        if snapshot {
            #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: evidence) == .empty)
        } else {
            let lines = evidence.split(separator: 0x0A)
            try #require(lines.count == 1)
            #expect(try JSONDecoder().decode(JournalRecord.self, from: lines[0]).outcome == .started)
        }
    }

    private static func reattachWithoutSynchronizing(_ target: URL) throws {
        let parent = target.deletingLastPathComponent()
        let detached = parent.appending(path: "detached-\(target.lastPathComponent)")
        var before = stat()
        try #require(lstat(target.path, &before) == 0)
        try #require(rename(target.path, detached.path) == 0)
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(directory >= 0)
        defer { close(directory) }
        try StateStore.fullySynchronize(directory, name: parent.lastPathComponent)
        try #require(rename(detached.path, target.path) == 0)
        var after = stat()
        try #require(lstat(target.path, &after) == 0)
        try #require(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
        try #require(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
        try #require(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
        try #require(before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
                     || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec)
    }
}
