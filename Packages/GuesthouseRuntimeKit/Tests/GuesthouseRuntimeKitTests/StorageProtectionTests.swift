import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StorageProtectionTests {
    @Test(arguments: [false, true]) func privateDirectoryPassesWithoutChangingItsContents(_ directoryURL: Bool) throws {
        let fixture = try Fixture()
        let directory = try fixture.directory("storage")
        let sentinel = directory.appending(path: "unpublished-work")
        try Data("keep me".utf8).write(to: sentinel)
        try StorageProtection.verify(directoryURL ? URL(fileURLWithPath: directory.path, isDirectory: true) : directory)
        #expect(try Data(contentsOf: sentinel) == Data("keep me".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["unpublished-work"])
    }

    @Test(arguments: [0o755, 0o770, 0o1700]) func modeDriftIsRefusedWithoutRepair(_ mode: Int) throws {
        let fixture = try Fixture()
        let directory = try fixture.directory("storage", mode: mode)
        #expect(throws: StorageFailure.protectionDrift) { try StorageProtection.verify(directory) }
        #expect(try StorageProtection.structure(directory).st_mode & 0o7777 == mode_t(mode))
    }

    @Test func leafACLIsRefusedButNeverRemoved() async throws {
        let fixture = try Fixture()
        let directory = try fixture.directory("storage")
        try await fixture.withACL("everyone allow read,list", at: directory) {
            #expect(throws: StorageFailure.protectionDrift) { try StorageProtection.verify(directory) }
            _ = try StorageProtection.structure(directory)
            #expect(throws: StorageFailure.protectionDrift) { try StorageProtection.verify(directory) }
        }
        try StorageProtection.verify(directory) // Explicit empty ACL after fixture cleanup also passes.
    }

    @Test(arguments: [false, true], [false, true])
    func finalLinksAreRefusedAndPreserved(_ dangling: Bool, _ directoryURL: Bool) throws {
        let fixture = try Fixture()
        let destination = fixture.root.appending(path: "target")
        if !dangling { _ = try fixture.directory("target") }
        let link = fixture.root.appending(path: "storage")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let inspected = directoryURL ? URL(fileURLWithPath: link.path, isDirectory: true) : link
        #expect(throws: StorageFailure.unsafeStructure) { try StorageProtection.verify(inspected) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination.path)
    }

    @Test func danglingAndNonDirectoryAncestorsArePreserved() throws {
        let fixture = try Fixture()
        let missing = fixture.root.appending(path: "missing")
        let alias = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: missing)
        #expect(throws: StorageFailure.unsafeStructure) { try StorageProtection.existingAncestors(of: alias.appending(path: "new")) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let blocker = fixture.root.appending(path: "blocker")
        try Data("keep me".utf8).write(to: blocker)
        #expect(throws: StorageFailure.unsafeStructure) { try StorageProtection.verify(blocker) }
        #expect(throws: StorageFailure.unsafeStructure) { try StorageProtection.existingAncestors(of: blocker.appending(path: "new")) }
        #expect(try Data(contentsOf: blocker) == Data("keep me".utf8))
    }

    @Test func validAncestorAliasAndItsRealParentsAreInspected() throws {
        let fixture = try Fixture()
        let target = try fixture.directory("target")
        let directory = try fixture.directory("target/storage")
        let alias = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        try StorageProtection.verify(alias.appending(path: "storage"))
        try StorageProtection.verify(directory)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == target.path)
    }

    @Test func unsafeAncestryIsRefusedBeforeCreation() throws {
        let fixture = try Fixture()
        let parent = try fixture.directory("exposed", mode: 0o777)
        #expect(throws: StorageFailure.unsafeStructure) { try StorageProtection.existingAncestors(of: parent.appending(path: "missing/deeper")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: parent.path)
        try StorageProtection.existingAncestors(of: parent.appending(path: "missing/deeper"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test func resolvedUnsafeAncestryCannotHideBehindAnAlias() throws {
        let fixture = try Fixture()
        _ = try fixture.directory("exposed", mode: 0o777)
        let target = try fixture.directory("exposed/target")
        let alias = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        #expect(throws: StorageFailure.unsafeStructure) { try StorageProtection.existingAncestors(of: alias.appending(path: "storage")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == target.path)
    }

    @Test(arguments: ["everyone deny delete", "everyone allow read,list"])
    func harmlessAncestorACLsRemainUsable(_ rule: String) async throws {
        let fixture = try Fixture()
        let parent = try fixture.directory("parent")
        try await fixture.withACL(rule, at: parent) {
            try StorageProtection.existingAncestors(of: parent.appending(path: "storage"))
        }
    }

    @Test func replacementRightsForAnotherPrincipalAreRefused() async throws {
        let fixture = try Fixture()
        let parent = try fixture.directory("parent")
        try await fixture.withACL("everyone allow add_file,delete_child", at: parent) {
            #expect(throws: StorageFailure.unsafeStructure) { try StorageProtection.existingAncestors(of: parent.appending(path: "storage")) }
        }
        try await fixture.withACL("\(NSUserName()) allow add_file,delete_child", at: parent) {
            try StorageProtection.existingAncestors(of: parent.appending(path: "storage"))
        }
    }

    @Test(arguments: [(Int32(-1), EINVAL, true), (-1, ENOENT, false), (-1, EIO, false),
                     (-1, EACCES, false), (-1, EBADF, false), (-1, EPERM, false),
                     (-1, ENOMEM, false), (-1, 0, false), (0, EINVAL, false)])
    func onlyDocumentedACLExhaustionIsAccepted(_ result: Int32, _ error: Int32, _ expected: Bool) {
        #expect(StorageProtection.enumerationFinished(result: result, error: error) == expected)
    }

    @Test func ownerPolicyAndUninspectableLocationsFailClosed() throws {
        #expect(StorageProtection.mayHoldEntry(owner: getuid()))
        #expect(StorageProtection.mayHoldEntry(owner: 0))
        #expect(!StorageProtection.mayHoldEntry(owner: getuid() &+ 1)) // Policy only; no foreign-owned fixture.
        let fixture = try Fixture()
        #expect(throws: StorageFailure.inspectionFailed) { try StorageProtection.verify(fixture.root.appending(path: "missing")) }
        #expect(throws: StorageFailure.invalidLocation) { try StorageProtection.verify(URL(string: "https://example.invalid/storage")!) }
        #expect(throws: StorageFailure.invalidLocation) { try StorageProtection.verify(URL(fileURLWithPath: fixture.root.path + "/bad\0suffix")) }
    }

    @Test(arguments: StorageFailure.allCases) func failuresContainOnlyFixedUsefulGuidance(_ failure: StorageFailure) {
        #expect(!failure.message.isEmpty)
        #expect(failure.recoveryActions == [.cancel])
        #expect(!failure.message.contains("Settings") && !failure.message.contains("/private/"))
    }

    private final class Fixture: Sendable {
        let root: URL
        init() throws {
            var template = Array("/private/tmp/guesthouse-storage-protection-XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else { throw StorageFailure.inspectionFailed }
            root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) } // Only this mkdtemp-owned fixture.
        func directory(_ name: String, mode: Int = 0o700) throws -> URL {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }
        func withACL(_ rule: String, at url: URL, body: () throws -> Void) async throws {
            defer {
                if let empty = acl_init(0) {
                    #expect(acl_set_link_np(url.path, ACL_TYPE_EXTENDED, empty) == 0)
                    acl_free(UnsafeMutableRawPointer(empty))
                } else { Issue.record("Could not clear the owned fixture ACL") }
            }
            let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/chmod"),
                arguments: ["+a", rule, url.path], timeout: .seconds(5)))
            let report = try await run.waitForExit()
            try #require(try report.childExit?.get() == .status(0) && !report.timedOut && !report.canceled)
            try body()
        }
    }
}
