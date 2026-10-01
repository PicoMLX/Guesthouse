import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct LumeBundleInspectionTests {
    @Test func missingReleaseAndAppAreDistinctFromUnsafeStorage() throws {
        let f = try Fixture()
        #expect(try LumeBundle.locate(in: f.storage) == nil)
        try f.directory(f.release)
        #expect(try LumeBundle.locate(in: f.storage) == nil)
        try f.directory(f.app)
        #expect(try LumeBundle.locate(in: f.storage)?.url == f.app)
        #expect(f.app.path.hasSuffix("/runtime/lume-v0.5.3/lume.app"))
        #expect(LumeBundle(url: f.app).fileIdentity == nil) // Discovery is not verification.
    }

    @Test(arguments: ["", "runtime", "runtime/lume-v0.5.3"], [false, true])
    func discoveryPreservesModeAndACLFailures(_ suffix: String, _ acl: Bool) throws {
        let f = try Fixture()
        try f.directory(f.release)
        let target = suffix.isEmpty ? f.root : f.root.appending(path: suffix)
        if acl { try FixtureACL.install(.everyoneRead, at: target) }
        else { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        #expect(throws: StorageFailure.protectionDrift) { _ = try LumeBundle.locate(in: f.storage) }
        #expect(throws: StorageFailure.protectionDrift) { try StorageProtection.verify(target) }
        #expect(try Data(contentsOf: f.sentinel) == Data("unpublished".utf8))
    }

    @Test(arguments: ["", "runtime", "runtime/lume-v0.5.3", "runtime/lume-v0.5.3/lume.app"], [false, true])
    func discoveryPreservesUnexpectedFilesAndLinks(_ suffix: String, _ link: Bool) throws {
        let f = try Fixture()
        try f.directory(f.release)
        let target = suffix.isEmpty ? f.root : f.root.appending(path: suffix)
        let preserved = f.base.appending(path: "preserved")
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: target, to: preserved)
        }
        if link { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: preserved) }
        else { try Data("keep unexpected file".utf8).write(to: target) }
        #expect(throws: StorageFailure.unsafeStructure) { _ = try LumeBundle.locate(in: f.storage) }
        if link {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == preserved.path)
        } else { #expect(try Data(contentsOf: target) == Data("keep unexpected file".utf8)) }
        let sentinel = suffix.isEmpty ? preserved.appending(path: "vms/unpublished") : f.sentinel
        #expect(try Data(contentsOf: sentinel) == Data("unpublished".utf8))
    }

    @Test(arguments: ["", "Contents", "Contents/MacOS", "Contents/Info.plist", "Contents/MacOS/lume"], [false, true])
    func criticalSnapshotRefusesLinksAndWrongTypes(_ suffix: String, _ link: Bool) throws {
        let f = try Fixture()
        try f.bundle()
        let target = suffix.isEmpty ? f.app : f.app.appending(path: suffix)
        let preserved = f.base.appending(path: "preserved")
        try FileManager.default.moveItem(at: target, to: preserved)
        if link { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: preserved) }
        else if suffix.contains(".plist") || suffix.hasSuffix("/lume") { try f.directory(target) }
        else { try Data("wrong type".utf8).write(to: target) }
        #expect(LumeBundle(url: f.app).fileIdentity == nil)
        #expect(FileManager.default.fileExists(atPath: preserved.path))
    }

    @Test(arguments: ["Contents/Info.plist", "Contents/MacOS/lume"])
    func snapshotsDetectSameSizeInPlaceWritesAndInnerReplacement(_ suffix: String) throws {
        let f = try Fixture()
        try f.bundle()
        let bundle = LumeBundle(url: f.app), file = f.app.appending(path: suffix)
        let before = try #require(bundle.fileIdentity)
        let oldItem = suffix.hasSuffix(".plist") ? before.infoPlist : before.executable
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("changed!".utf8))
        try handle.close()
        // Deterministic timestamp change without a sleep or changing the inode/length.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        let rewritten = try #require(bundle.fileIdentity)
        let rewrittenItem = suffix.hasSuffix(".plist") ? rewritten.infoPlist : rewritten.executable
        #expect(rewrittenItem.version.identity == oldItem.version.identity)
        #expect(rewrittenItem.bytes == oldItem.bytes)
        #expect(rewritten != before)
        let preserved = f.base.appending(path: "original")
        try FileManager.default.moveItem(at: file, to: preserved)
        try Data("new file".utf8).write(to: file)
        let replaced = try #require(bundle.fileIdentity)
        #expect(replaced.bundle.version.identity == before.bundle.version.identity)
        #expect(replaced != rewritten)
        #expect(try Data(contentsOf: preserved) == Data("changed!".utf8))
    }

    @Test func snapshotRejectsAnIntermediateReleaseLinkWithUnchangedBundleFiles() throws {
        let f = try Fixture()
        try f.bundle()
        let bundle = LumeBundle(url: f.app)
        let before = try #require(bundle.fileIdentity)
        let preserved = f.base.appending(path: "preserved-release")
        try FileManager.default.moveItem(at: f.release, to: preserved)
        try FileManager.default.createSymbolicLink(at: f.release, withDestinationURL: preserved)
        var info = stat()
        try #require(lstat(f.app.path, &info) == 0)
        #expect(LumeBundleFileIdentity.Item(info) == before.bundle)
        #expect(bundle.fileIdentity == nil)
        #expect(throws: StorageFailure.unsafeStructure) { _ = try LumeBundle.locate(in: f.storage) }
        #expect(try Data(contentsOf: preserved.appending(path: "lume.app/Contents/MacOS/lume")) == Data("original".utf8))
    }

    @Test(arguments: LumeVerificationError.allCases)
    func failuresCarryOnlyOwnedActionablePresentation(_ failure: LumeVerificationError) throws {
        #expect(failure.errorDescription == failure.userMessage)
        #expect(failure.localizedDescription == failure.userMessage)
        #expect(!failure.recoveryActions.isEmpty)
        #expect(failure.recoveryActions.contains(.cancel))
        #expect(!failure.userMessage.contains("/private/"))
        let copy: any Sendable = failure
        #expect(copy as? LumeVerificationError == failure)
        if failure == .insecureBundleLayout { #expect(failure.recoveryActions == [.cancel]) }
    }

    private final class Fixture: Sendable {
        let base, root, app: URL
        let storage: RuntimeStorage
        var release: URL { app.deletingLastPathComponent() }
        var sentinel: URL { root.appending(path: "vms/unpublished") }
        init() throws {
            var template = Array("/private/tmp/guesthouse-lume-inspection-XXXXXX".utf8CString)
            let name = try #require(mkdtemp(&template))
            base = URL(fileURLWithPath: String(cString: name))
            root = base.appending(path: "Guesthouse")
            storage = try RuntimeStorage(root: root)
            app = try LumeBundle.expectedLocation(in: storage)
            try Data("unpublished".utf8).write(to: sentinel)
        }
        deinit { try? FileManager.default.removeItem(at: base) } // Only this mkdtemp fixture.
        func directory(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        func bundle() throws {
            try directory(app.appending(path: "Contents/MacOS"))
            // Benign non-code fixtures. No provider artifact is installed or executed.
            for suffix in ["Contents/Info.plist", "Contents/MacOS/lume"] {
                try Data("original".utf8).write(to: app.appending(path: suffix))
            }
        }
    }
}
