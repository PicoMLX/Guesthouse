import Foundation
import GuesthouseCore
import Security
import Testing
@testable import GuesthouseRuntimeKit

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
            let run = try await ProcessRunner().run(ProcessInvocation(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--sign", "-", "--identifier", identifier, url.path],
                timeout: .seconds(30)
            ))
            for await _ in run.output {}
            let exit = await run.exit()
            precondition(exit.succeeded, "ad-hoc signing failed")
        }
    }
}

@Suite(.serialized) struct LumeBundleTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "LumeBundleTests-\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        #expect(LumeBundle.locate(in: storage) == nil)
        let expected = LumeBundle.expectedLocation(in: storage)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        #expect(LumeBundle.locate(in: storage)?.url == expected)
        #expect(expected.path.hasSuffix("/runtime/lume-v0.5.3/lume.app"))
    }

    @Test func locateRejectsSymlinkedManagedComponents() throws {
        let storage = try RuntimeStorage(root: root.appending(path: "symlink-storage"))
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let release = storage.url(for: .runtime).appending(path: LumePin.releaseTag)
        try FileManager.default.createSymbolicLink(at: release, withDestinationURL: outside)
        try FileManager.default.createDirectory(at: outside.appending(path: LumePin.bundleName), withIntermediateDirectories: true)
        #expect(LumeBundle.locate(in: storage) == nil)
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
        #expect(LumeBundle.locate(in: storage) == nil)
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
        #expect(throws: LumeVerificationError.archiveUnreadable) {
            try LumeBundle.verifyArchiveDigest(of: root.appending(path: "missing.bin"))
        }
    }
}
