import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct RuntimeStorageHardeningTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "RuntimeStorageHardening-\(UUID().uuidString)")

    func isExcluded(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    @Test func staleBackupExclusionsAreClearedOnIncludedDirectories() throws {
        _ = try RuntimeStorage(root: root)
        for subdirectory in [RuntimeStorage.Subdirectory.state, .vms] {
            var url = root.appending(path: subdirectory.rawValue)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            #expect(try isExcluded(url))
        }
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try rootURL.setResourceValues(values)
        let storage = try RuntimeStorage(root: root)
        #expect(try !isExcluded(storage.root))
        #expect(try !isExcluded(storage.url(for: .state)))
        #expect(try !isExcluded(storage.url(for: .vms)))
        #expect(try isExcluded(storage.url(for: .staging)))
    }

    @Test func accessControlEntriesAreRemoved() throws {
        _ = try RuntimeStorage(root: root)
        let target = root.appending(path: RuntimeStorage.Subdirectory.sshMaintenance.rawValue)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,list", target.path]
        chmod.environment = [:]
        try chmod.run()
        chmod.waitUntilExit()
        try #require(chmod.terminationStatus == 0)
        #expect(try RuntimeStorage.hasAccessControlEntries(target))
        _ = try RuntimeStorage(root: root)
        #expect(try !RuntimeStorage.hasAccessControlEntries(target))
        #expect(throws: RuntimeStorageError.self) { try RuntimeStorage.hasAccessControlEntries(root.appending(path: "missing")) }
    }

    @Test func aWorldWritableContainingFolderIsRefused() throws {
        // A 0700 directory is only as private as what is above it: an ancestor anyone can
        // write to can be renamed away and replaced, and everything written afterwards would
        // land in the replacement.
        let open = root.appending(path: "open")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
        let inside = open.appending(path: "storage")
        let error = #expect(throws: RuntimeStorageError.self) { _ = try RuntimeStorage(root: inside) }
        if case .insecureDirectory(_, let reason)? = error {
            #expect(reason.contains("other users"))
        } else {
            Issue.record("expected an insecure-directory refusal, got \(String(describing: error))")
        }
        // The same folder with the sticky bit is the rule that makes /tmp safe, and is allowed.
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: open.path)
        #expect(throws: Never.self) { _ = try RuntimeStorage(root: open.appending(path: "sticky")) }
    }

    @Test func errorsAreActionable() {
        let insecure = RuntimeStorageError.insecureDirectory(path: "/x", reason: "symbolic link")
        let unwritable = RuntimeStorageError.unwritable(
            path: "/x",
            reason: SanitizedText("No space left on device")
        )
        let errors = [insecure, unwritable]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
            #expect(error.errorDescription == error.userMessage)
            #expect(!error.userMessage.contains("Settings"))
            #expect(error.userMessage.contains("unpublished work"))
        }
        #expect(insecure.recoveryActions == [.cancel])
        #expect(insecure.userMessage.contains("Preserve"))
        #expect(!insecure.userMessage.contains("move or remove"))
        #expect(!insecure.userMessage.contains("delete"))
        #expect(unwritable.recoveryActions == [.freeDiskSpace, .retry, .cancel])
    }

    @Test func aNonDirectoryRootAncestorIsRefusedAndPreserved() throws {
        let blocker = root.appending(path: "not-a-directory")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: blocker)

        #expect(throws: RuntimeStorageError.insecureDirectory(path: blocker.path, reason: "not a directory")) {
            try RuntimeStorage(root: blocker.appending(path: "Guesthouse"))
        }

        #expect(try String(contentsOf: blocker, encoding: .utf8) == "keep me")
    }
}
