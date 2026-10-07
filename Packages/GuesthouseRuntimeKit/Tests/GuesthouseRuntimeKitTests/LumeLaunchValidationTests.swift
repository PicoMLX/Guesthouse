import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

struct LumeLaunchValidationTests {
    @Test func matchingCoherenceStillRequiresTheStrictSignatureGate() throws {
        let f = try Fixture(), bundle = LumeBundle(url: f.app)
        let identity = try #require(bundle.fileIdentity)
        #expect(try LumeLaunchValidation.relocate(expected: bundle, identity: identity, in: f.storage) == bundle)
        // The fixture has exact pinned metadata and an executable benign file, but no signature.
        #expect(throws: LumeVerificationError.signatureInvalid) {
            _ = try LumeLaunchValidation.reverify(expected: bundle, identity: identity, in: f.storage)
        }
    }

    @Test func anotherStorageCannotBorrowTheVerifiedRootsLease() throws {
        let a = try Fixture(), b = try Fixture(), bundle = LumeBundle(url: a.app)
        let identity = try #require(bundle.fileIdentity)
        #expect(throws: LumeLaunchValidationError.storageMismatch) {
            _ = try LumeLaunchValidation.relocate(expected: bundle, identity: identity, in: b.storage)
        }
        #expect(try Data(contentsOf: a.sentinel) == Data("unpublished".utf8))
        #expect(try Data(contentsOf: b.sentinel) == Data("unpublished".utf8))
    }

    @Test(arguments: ["Contents/Info.plist", "Contents/MacOS/lume"], [false, true])
    func everyRecheckDetectsInnerReplacementAndSameInodeWrites(_ suffix: String, _ replace: Bool) throws {
        let f = try Fixture(), bundle = LumeBundle(url: f.app)
        let identity = try #require(bundle.fileIdentity)
        _ = try LumeLaunchValidation.relocate(expected: bundle, identity: identity, in: f.storage)
        let file = f.app.appending(path: suffix)
        if replace {
            try FileManager.default.moveItem(at: file, to: f.base.appending(path: "preserved"))
            try Data("changed".utf8).write(to: file)
        } else {
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data("changed".utf8))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        }
        #expect(bundle.fileIdentity?.bundle == identity.bundle) // Outer app was not replaced.
        #expect(throws: LumeLaunchValidationError.bundleChanged) {
            _ = try LumeLaunchValidation.reverify(expected: bundle, identity: identity, in: f.storage)
        }
    }

    @Test(arguments: ["", "runtime", "runtime/lume-v0.5.3"], [false, true])
    func unsafeManagedPathsPreserveTheirStorageFailure(_ suffix: String, _ link: Bool) throws {
        let f = try Fixture(), bundle = LumeBundle(url: f.app)
        let identity = try #require(bundle.fileIdentity)
        let target = suffix.isEmpty ? f.root : f.root.appending(path: suffix)
        if link {
            let preserved = f.base.appending(path: "preserved")
            try FileManager.default.moveItem(at: target, to: preserved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: preserved)
        } else { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        #expect(throws: link ? StorageFailure.unsafeStructure : .protectionDrift) {
            _ = try LumeLaunchValidation.reverify(expected: bundle, identity: identity, in: f.storage)
        }
        #expect(StorageFailure.unsafeStructure.recoveryActions == [.cancel])
        let sentinel = link && suffix.isEmpty ? f.base.appending(path: "preserved/vms/unpublished") : f.sentinel
        #expect(try Data(contentsOf: sentinel) == Data("unpublished".utf8))
    }

    @Test func missingAndUnsafeInnerFilesAreNotLaunchable() throws {
        let f = try Fixture(), bundle = LumeBundle(url: f.app)
        let identity = try #require(bundle.fileIdentity)
        let file = bundle.executable, preserved = f.base.appending(path: "preserved")
        try FileManager.default.moveItem(at: file, to: preserved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: preserved)
        #expect(throws: LumeVerificationError.insecureBundleLayout) {
            _ = try LumeLaunchValidation.reverify(expected: bundle, identity: identity, in: f.storage)
        }
        try FileManager.default.moveItem(at: f.app, to: f.base.appending(path: "preserved-app"))
        #expect(throws: LumeLaunchValidationError.bundleChanged) {
            _ = try LumeLaunchValidation.reverify(expected: bundle, identity: identity, in: f.storage)
        }
        #expect(try Data(contentsOf: preserved) == Data("benign fixture".utf8))
    }

    @Test(arguments: LumeLaunchValidationError.allCases) func failuresUseOwnedMessages(_ error: LumeLaunchValidationError) {
        #expect(error.localizedDescription == error.userMessage)
        #expect(!error.userMessage.isEmpty && !error.userMessage.contains("/"))
        #expect(error.recoveryActions.contains(.cancel))
        if error == .storageMismatch { #expect(error.recoveryActions == [.inspectState, .cancel]) }
    }

    private final class Fixture: Sendable {
        let base, root, app: URL
        let storage: RuntimeStorage
        var sentinel: URL { root.appending(path: "vms/unpublished") }
        init() throws {
            var template = Array("/private/tmp/guesthouse-lume-launch-check-XXXXXX".utf8CString)
            base = URL(fileURLWithPath: String(cString: try #require(mkdtemp(&template))))
            root = base.appending(path: "Guesthouse")
            storage = try RuntimeStorage(root: root)
            app = try LumeBundle.expectedLocation(in: storage)
            try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let metadata = ["CFBundleIdentifier": LumePin.bundleIdentifier,
                            "CFBundleShortVersionString": LumePin.version.description,
                            "CFBundleExecutable": LumePin.executableName]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: app.appending(path: "Contents/Info.plist"))
            let file = app.appending(path: "Contents/MacOS/lume")
            try Data("benign fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            try Data("unpublished".utf8).write(to: sentinel)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
