import Foundation
import GuesthouseCore
import Security
import Testing
@testable import GuesthouseRuntimeKit

private func signAdHoc(_ bundle: URL, identifier: String) async throws {
    let run = try await ProcessRunner().run(ProcessInvocation(
        executable: URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: ["--force", "--sign", "-", "--identifier", identifier, bundle.path],
        timeout: .seconds(30)
    ))
    for await _ in run.output {}
    let exit = await run.exit()
    precondition(exit.succeeded, "ad-hoc signing failed")
}

private struct DummyLumeBundle {
    let url: URL

    init(
        root: URL,
        identifier: String = LumePin.bundleIdentifier,
        version: String = LumePin.version.description,
        executableName: String = LumePin.executableName,
        executable: Bool = true,
        sign: Bool = false
    ) async throws {
        url = root.appending(path: LumePin.bundleName)
        let contents = url.appending(path: "Contents")
        let executables = contents.appending(path: "MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": executableName,
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        if executable {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/bin/echo"),
                to: executables.appending(path: LumePin.executableName)
            )
        }
        if sign {
            try await signAdHoc(url, identifier: identifier)
        }
    }
}

@Suite(.serialized) struct LumeBundleTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "LumeBundleTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    @Test func releaseFactsStayInternallyConsistent() {
        #expect(LumePin.version.description == "0.5.3")
        #expect(LumePin.releaseTag == "lume-v\(LumePin.version)")
        #expect(LumePin.archiveSHA256.count == 64)
        #expect(LumePin.codeDirectoryHash.count == 40)
        #expect(LumePin.executableSHA256.count == 64)
        #expect(LumePin.downloadURL.host() == "github.com")
        #expect(LumePin.downloadURL.path().hasSuffix("/\(LumePin.releaseTag)/\(LumePin.archiveName)"))
        #expect(LumePin.codeRequirement.contains(LumePin.teamIdentifier))
        #expect(LumePin.codeRequirement.contains(LumePin.bundleIdentifier))
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(LumePin.codeRequirement as CFString, [], &requirement) == errSecSuccess)
        #expect(requirement != nil)
        let failure = LumeVerificationError.signatureInvalid(status: -1)
        #expect(failure.errorDescription == failure.userMessage)
        #expect(failure.localizedDescription == failure.userMessage)
        #expect(failure.recoveryActions == [.repair(.runtime), .cancel])
    }

    @Test func locateUsesOnlyThePrivatePinnedDirectory() throws {
        let storage = try RuntimeStorage(root: root.appending(path: "storage"))
        #expect(try LumeBundle.locate(in: storage) == nil)
        let expected = LumeBundle.expectedLocation(in: storage)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        #expect(try LumeBundle.locate(in: storage)?.url == expected)
        #expect(expected.path.hasSuffix("/runtime/lume-v0.5.3/lume.app"))
    }

    @Test func locateRejectsSymlinkedManagedComponents() throws {
        let storage = try RuntimeStorage(root: root.appending(path: "symlink-storage"))
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let release = storage.url(for: .runtime).appending(path: LumePin.releaseTag)
        try FileManager.default.createSymbolicLink(at: release, withDestinationURL: outside)
        try FileManager.default.createDirectory(at: outside.appending(path: LumePin.bundleName), withIntermediateDirectories: true)
        #expect(throws: RuntimeStorageError.insecureDirectory(path: release.path, reason: "symbolic link")) {
            try LumeBundle.locate(in: storage)
        }
    }

    @Test func locateReportsASymlinkedAppAsUnsafeStorage() throws {
        let storage = try RuntimeStorage(root: root.appending(path: "symlinked-app-storage"))
        let outside = root.appending(path: "outside-app")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let app = LumeBundle.expectedLocation(in: storage)
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: outside)

        #expect(throws: RuntimeStorageError.insecureDirectory(path: app.path, reason: "symbolic link")) {
            try LumeBundle.locate(in: storage)
        }
    }

    @Test func locateRechecksTheRuntimeRootAfterStorageInitialization() throws {
        let storage = try RuntimeStorage(root: root.appending(path: "replaced-runtime-storage"))
        let runtime = storage.url(for: .runtime)
        let moved = root.appending(path: "moved-runtime")
        try FileManager.default.moveItem(at: runtime, to: moved)
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: moved)
        try FileManager.default.createDirectory(
            at: moved.appending(path: "\(LumePin.releaseTag)/\(LumePin.bundleName)"),
            withIntermediateDirectories: true
        )
        #expect(throws: RuntimeStorageError.insecureDirectory(path: runtime.path, reason: "symbolic link")) {
            try LumeBundle.locate(in: storage)
        }
    }

    @Test func missingMetadataAndExecutableAreRejectedBeforeExecution() async throws {
        let missing = root.appending(path: "missing/lume.app")
        #expect(throws: LumeVerificationError.bundleMissing(path: missing.path)) {
            try LumeBundle(url: missing).verify()
        }
        let empty = root.appending(path: "empty/lume.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: LumeVerificationError.insecureBundleLayout) {
            try LumeBundle(url: empty).verify()
        }
        let noExecutable = try await DummyLumeBundle(root: root.appending(path: "no-executable"), executable: false)
        try Data().write(to: noExecutable.url.appending(path: "Contents/MacOS/\(LumePin.executableName)"))
        #expect(throws: LumeVerificationError.executableMissing) {
            try LumeBundle(url: noExecutable.url).verify()
        }
    }

    @Test func identifierAndVersionMismatchesAreSanitizedAndRejected() async throws {
        let wrongIdentifier = try await DummyLumeBundle(root: root.appending(path: "identifier"), identifier: "com.example.lume")
        #expect(throws: LumeVerificationError.bundleIdentifierMismatch(found: SanitizedText("com.example.lume", limit: 80))) {
            try LumeBundle(url: wrongIdentifier.url).verify()
        }
        let wrongVersion = try await DummyLumeBundle(root: root.appending(path: "version"), version: "0.5.2")
        #expect(throws: LumeVerificationError.versionMismatch(found: SanitizedText("0.5.2", limit: 40))) {
            try LumeBundle(url: wrongVersion.url).verify()
        }
        let wrongExecutable = try await DummyLumeBundle(root: root.appending(path: "executable-name"), executableName: "other")
        #expect(throws: LumeVerificationError.executableNameMismatch(found: SanitizedText("other", limit: 80))) {
            try LumeBundle(url: wrongExecutable.url).verify()
        }
    }

    @Test func oversizedInfoPlistIsRejectedWithoutLoadingItUnbounded() async throws {
        let fixture = try await DummyLumeBundle(root: root.appending(path: "huge-plist"))
        try Data(repeating: 0x20, count: (1 << 20) + 1)
            .write(to: fixture.url.appending(path: "Contents/Info.plist"))
        #expect(throws: LumeVerificationError.infoPlistUnreadable) {
            try LumeBundle(url: fixture.url).verify()
        }
    }

    @Test func verifierRejectsASymlinkedExecutableBeforeSignatureChecks() async throws {
        let fixture = try await DummyLumeBundle(root: root.appending(path: "linked-executable"), executable: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.url.appending(path: "Contents/MacOS/\(LumePin.executableName)"),
            withDestinationURL: URL(fileURLWithPath: "/bin/echo")
        )
        #expect(throws: LumeVerificationError.insecureBundleLayout) {
            try LumeBundle(url: fixture.url).verify()
        }
    }

    @Test func verifiedTokenTracksTheCriticalMetadataAndExecutableFiles() async throws {
        let fixture = try await DummyLumeBundle(root: root.appending(path: "identity-snapshot"))
        let bundle = LumeBundle(url: fixture.url)
        let verified = try VerifiedLumeBundle(
            bundle: bundle,
            version: LumePin.version,
            teamIdentifier: LumePin.teamIdentifier,
            signingIdentifier: LumePin.bundleIdentifier
        )
        #expect(verified.matchesVerifiedFiles(in: bundle))

        let originalExecutable = fixture.url.appending(path: "Contents/MacOS/lume-before-replacement")
        try FileManager.default.moveItem(at: bundle.executable, to: originalExecutable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: bundle.executable)

        #expect(!verified.matchesVerifiedFiles(in: bundle))
        #expect(RuntimeStorage.fileIdentity(of: fixture.url) == verified.verifiedFileIdentity.bundle.coordination)
    }

    @Test func verifiedTokenRejectsInPlaceWritesThatKeepTheSameInode() async throws {
        let executableFixture = try await DummyLumeBundle(root: root.appending(path: "in-place-executable"))
        let executableBundle = LumeBundle(url: executableFixture.url)
        let executableToken = try VerifiedLumeBundle(
            bundle: executableBundle,
            version: LumePin.version,
            teamIdentifier: LumePin.teamIdentifier,
            signingIdentifier: LumePin.bundleIdentifier
        )
        let executableIdentity = RuntimeStorage.fileIdentity(of: executableBundle.executable)
        let executableHandle = try FileHandle(forWritingTo: executableBundle.executable)
        try executableHandle.write(contentsOf: Data([0]))
        try executableHandle.close()
        #expect(RuntimeStorage.fileIdentity(of: executableBundle.executable) == executableIdentity)
        #expect(!executableToken.matchesVerifiedFiles(in: executableBundle))

        let plistFixture = try await DummyLumeBundle(root: root.appending(path: "in-place-plist"))
        let plistBundle = LumeBundle(url: plistFixture.url)
        let plistToken = try VerifiedLumeBundle(
            bundle: plistBundle,
            version: LumePin.version,
            teamIdentifier: LumePin.teamIdentifier,
            signingIdentifier: LumePin.bundleIdentifier
        )
        let plistURL = plistFixture.url.appending(path: "Contents/Info.plist")
        let plistIdentity = RuntimeStorage.fileIdentity(of: plistURL)
        let plistHandle = try FileHandle(forWritingTo: plistURL)
        try plistHandle.write(contentsOf: Data([0]))
        try plistHandle.close()
        #expect(RuntimeStorage.fileIdentity(of: plistURL) == plistIdentity)
        #expect(!plistToken.matchesVerifiedFiles(in: plistBundle))
    }

    @Test func adHocSignatureCannotSatisfyThePinnedDeveloperIDRequirement() async throws {
        let adHoc = try await DummyLumeBundle(root: root.appending(path: "adhoc"), sign: true)
        do {
            _ = try LumeBundle(url: adHoc.url).verify()
            Issue.record("an ad-hoc bundle must not verify")
        } catch LumeVerificationError.signatureInvalid {
        } catch LumeVerificationError.requirementNotMet {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func invalidNestedCodeIsRejectedBeforeThePinnedRequirement() async throws {
        let outer = try await DummyLumeBundle(root: root.appending(path: "invalid-nested-code"))
        let helper = outer.url.appending(path: "Contents/Helpers/Helper.app")
        let helperContents = helper.appending(path: "Contents")
        let helperExecutable = helperContents.appending(path: "MacOS/Helper")
        let sealedResource = helperContents.appending(path: "Resources/value.txt")
        try FileManager.default.createDirectory(
            at: helperExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sealedResource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: helperExecutable)
        try Data("before".utf8).write(to: sealedResource)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.guesthouse.fixture.helper",
            "CFBundleExecutable": "Helper",
            "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0).write(to: helperContents.appending(path: "Info.plist"))
        try await signAdHoc(helper, identifier: "com.guesthouse.fixture.helper")
        try await signAdHoc(outer.url, identifier: LumePin.bundleIdentifier)
        try Data("after-tampering".utf8).write(to: sealedResource)

        var staticCode: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(outer.url as CFURL, [], &staticCode) == errSecSuccess)
        let code = try #require(staticCode)
        let shallowFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        #expect(SecStaticCodeCheckValidityWithErrors(code, shallowFlags, nil, nil) == errSecSuccess)

        do {
            _ = try LumeBundle(url: outer.url).verify()
            Issue.record("tampered nested code must not verify")
        } catch LumeVerificationError.signatureInvalid(let status) {
            #expect(status != errSecSuccess)
        } catch {
            Issue.record("nested-code validation failed at the wrong gate: \(error)")
        }
    }

    @Test func archiveDigestIsStreamedAndCompared() throws {
        let archive = root.appending(path: "archive.bin")
        try Data("hello".utf8).write(to: archive)
        try LumeBundle.verifyArchiveDigest(
            of: archive,
            expected: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
        #expect(throws: LumeVerificationError.digestMismatch) {
            try LumeBundle.verifyArchiveDigest(of: archive, expected: String(repeating: "0", count: 64))
        }
        #expect(throws: LumeVerificationError.digestMismatch) {
            try LumeBundle.verifyArchiveDigest(of: archive)
        }
        #expect(throws: LumeVerificationError.archiveUnreadable) {
            try LumeBundle.verifyArchiveDigest(of: root.appending(path: "missing.bin"))
        }
    }
}
