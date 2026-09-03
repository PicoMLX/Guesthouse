import Foundation
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct RuntimeStorageTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "RuntimeStorageTests-\(UUID().uuidString)")

    func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func createsEveryDirectoryWithRestrictivePermissions() throws {
        let storage = try RuntimeStorage(root: base.appending(path: "Guesthouse"))
        #expect(try permissions(storage.root) == 0o700)
        for subdirectory in RuntimeStorage.Subdirectory.allCases {
            let url = storage.url(for: subdirectory)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue, Comment(rawValue: subdirectory.rawValue))
            #expect(try permissions(url) == 0o700, Comment(rawValue: subdirectory.rawValue))
        }
        #expect(storage.url(for: .sshMaintenance).path.hasSuffix("/Guesthouse/ssh/maintenance"))
        #expect(try permissions(storage.root.appending(path: "ssh")) == 0o700, "intermediate directories are restricted too")
    }

    @Test func tartHomeIsTheVMStoreAndTheEnvironmentHasNothingElse() throws {
        let storage = try RuntimeStorage(root: base)
        #expect(storage.tartHome == base.standardizedFileURL.appending(path: "vms"))
        #expect(storage.environmentForTart() == ["TART_HOME": storage.tartHome.path])
    }

    @Test func largeOrTransientDirectoriesAreExcludedFromBackup() throws {
        let storage = try RuntimeStorage(root: base)
        for subdirectory in RuntimeStorage.Subdirectory.allCases {
            let excluded = try storage.url(for: subdirectory).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
            #expect(excluded == subdirectory.isExcludedFromBackup, Comment(rawValue: subdirectory.rawValue))
        }
    }

    @Test func symlinkedSubdirectoryIsRefused() throws {
        let outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let root = base.appending(path: "root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "vms"), withDestinationURL: outside)
        #expect(throws: RuntimeStorageError.insecureDirectory(path: root.appending(path: "vms").path, reason: "symbolic link")) {
            try RuntimeStorage(root: root)
        }
    }

    @Test func symlinkedRootIsRefused() throws {
        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: RuntimeStorageError.self) { try RuntimeStorage(root: link) }
    }

    @Test func aFileWhereADirectoryBelongsIsRefused() throws {
        let root = base.appending(path: "root2")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "state"))
        #expect(throws: RuntimeStorageError.insecureDirectory(path: root.appending(path: "state").path, reason: "not a directory")) {
            try RuntimeStorage(root: root)
        }
    }

    @Test func reopeningExistingStorageTightensPermissions() throws {
        let root = base.appending(path: "root3")
        try FileManager.default.createDirectory(at: root.appending(path: "state"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let storage = try RuntimeStorage(root: root)
        #expect(try permissions(storage.url(for: .state)) == 0o700)
    }

    @Test func defaultRootIsUnderApplicationSupport() throws {
        let url = try RuntimeStorage.defaultRoot()
        #expect(url.path.hasSuffix("/Library/Application Support/Guesthouse"))
    }
}
