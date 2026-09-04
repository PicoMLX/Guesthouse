import Foundation
import Security
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

/// Builds a throwaway `tart.app` with a chosen Info.plist and an ad-hoc signature, so the
/// verifier's failure paths can be exercised without the real release.
struct DummyBundle {
    let url: URL

    init(root: URL, identifier: String = TartRelease.signingIdentifier, version: String = TartPin.releaseTag, executable: Bool = true, sign: Bool = true) async throws {
        url = root.appending(path: TartRelease.bundleName)
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": TartRelease.executableName, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        if executable {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: contents.appending(path: "MacOS/\(TartRelease.executableName)"))
        }
        if sign {
            let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", "--identifier", identifier, url.path], timeout: .seconds(30)))
            for await _ in run.output {}
            let exit = await run.exit()
            precondition(exit.succeeded, "ad-hoc signing failed")
        }
    }
}

@Suite(.serialized) struct TartBundleTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "TartBundleTests-\(UUID().uuidString)")

    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }

    @Test func aRuntimeReplacedAfterVerificationIsNotRun() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Verified-\(UUID().uuidString)")
        let executable = root.appending(path: "tart.app/Contents/MacOS/tart")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let bundle = TartBundle(url: root.appending(path: "tart.app"))
        let storage = try RuntimeStorage(root: root.appending(path: "state"))
        let runner = FakeProcessRunner(stdout: ["2.36.0"], exit: ProcessExit(reason: .status(0)))
        // A link is not a regular file, so it has no identity to bind to: the launch is
        // refused rather than trusted.
        let file = TartBundle.FileIdentity(device: 1, inode: 2, size: 3, modified: timespec(), changed: timespec())
        let backend = TartBackend(bundle: bundle, storage: storage, runner: runner, verifiedBundle: TartBundle.BundleIdentity(directoryDevice: 1, directoryInode: 2, infoPlist: file, executable: file))
        await #expect(throws: TartInvocationError.runtimeReplaced) { _ = try await backend.version() }
        #expect(await runner.invocations.isEmpty, "nothing was launched")
    }

    /// Verification records the bundle that passed rather than leaving the caller to read it
    /// again. The identity is a field of the result, so there is no absent one to hand on: a
    /// caller that took "no identity" for "no check needed" would launch whatever replaced it.
    @Test func verificationCarriesTheBundleItPassedOn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Identity-\(UUID().uuidString)")
        let dummy = try await DummyBundle(root: root, sign: false)
        let bundle = TartBundle(url: dummy.url)
        let identity = try #require(bundle.identity)
        #expect(TartVerification(version: TartRelease.version, teamIdentifier: "T", signingIdentifier: "S", bundle: identity).bundle == identity)

        // A link is not a regular file, so a second read of the same path yields nothing at
        // all — which is exactly the value verification no longer lets a caller receive.
        try FileManager.default.removeItem(at: bundle.executable)
        try FileManager.default.createSymbolicLink(at: bundle.executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(bundle.executableIdentity == nil)
        #expect(bundle.identity == nil, "a bundle whose executable cannot be identified has no identity of its own")
    }

    /// Modification time can be set back to whatever it was; the inode's change time cannot.
    @Test func anInPlaceOverwriteChangesTheExecutableIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Overwrite-\(UUID().uuidString)")
        let dummy = try await DummyBundle(root: root, sign: false)
        let bundle = TartBundle(url: dummy.url)
        let before = try #require(bundle.executableIdentity)
        let original = try Data(contentsOf: bundle.executable)

        // Same file, same size, and the modification time put back exactly as it was: only
        // the change time records that the bytes were rewritten.
        var replacement = original
        replacement[replacement.count - 1] = replacement[replacement.count - 1] ^ 0x01
        let handle = try FileHandle(forWritingTo: bundle.executable)
        try handle.write(contentsOf: replacement)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(before.modified.tv_sec))], ofItemAtPath: bundle.executable.path)

        let after = try #require(bundle.executableIdentity)
        #expect(after.device == before.device && after.inode == before.inode && after.size == before.size)
        #expect(after != before, "an in-place overwrite that restores the modification time is still a different file")
    }

    /// The verified state has to mean the whole bundle. A replacement can hard-link the
    /// verified executable into a bundle of its own: that file's device, inode, size, and
    /// times are then all still the ones that passed, while the `Info.plist`, the resources,
    /// and the nested code around it passed nothing.
    @Test func aBundleRebuiltAroundTheVerifiedExecutableIsNotTheVerifiedBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Relinked-\(UUID().uuidString)")
        let dummy = try await DummyBundle(root: root, sign: false)
        let bundle = TartBundle(url: dummy.url)

        // Another bundle with the executable hard-linked into it — the same inode, so every
        // field of its identity is shared — prepared before verification records anything.
        let elsewhere = root.appending(path: "elsewhere")
        let substitute = try await DummyBundle(root: elsewhere, sign: false)
        let planted = substitute.url.appending(path: "Contents/MacOS/\(TartRelease.executableName)")
        try FileManager.default.removeItem(at: planted)
        try FileManager.default.linkItem(at: bundle.executable, to: planted)

        let verified = try #require(bundle.identity)

        // The bundle that passed is renamed away and the other one takes its pathname. The
        // executable at that path is still the very inode that was verified.
        try FileManager.default.moveItem(at: bundle.url, to: root.appending(path: "verified-aside"))
        try FileManager.default.moveItem(at: substitute.url, to: bundle.url)

        #expect(bundle.executableIdentity == verified.executable, "the executable is the very file that was verified")
        #expect(bundle.identity != verified, "a different bundle around it is a different bundle")

        let storage = try RuntimeStorage(root: root.appending(path: "state"))
        let runner = FakeProcessRunner(stdout: ["2.36.0"], exit: ProcessExit(reason: .status(0)))
        let backend = TartBackend(bundle: bundle, storage: storage, runner: runner, verifiedBundle: verified)
        await #expect(throws: TartInvocationError.runtimeReplaced) { _ = try await backend.version() }
        #expect(await runner.invocations.isEmpty, "nothing was launched")
    }

    /// The requirement string is compiled by `SecRequirementCreateWithString`; a form it
    /// rejects would make every bundle, including the official one, fail verification.
    @Test func theDeveloperIDRequirementCompiles() throws {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(TartRelease.codeRequirement as CFString, [], &requirement)
        #expect(status == errSecSuccess, "the pinned requirement did not compile (OSStatus \(status))")
        #expect(requirement != nil)
    }

    @Test func anExecutableReplacedAfterTheLaunchIsEndedNotSpokenTo() async throws {
        /// Replaces the bundle's executable at the moment the launch happens: the file that
        /// passed verification is gone by the time the child exists.
        struct SwappingRunner: ProcessRunning {
            let executable: URL
            let inner = FakeProcessRunner(stdout: ["2.36.0"], exit: ProcessExit(reason: .status(0)))
            func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
                try? FileManager.default.removeItem(at: executable)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/cat"), to: executable)
                return try await inner.run(invocation)
            }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "Swap-\(UUID().uuidString)")
        let storage = try RuntimeStorage(root: root.appending(path: "state"))
        let dummy = try await DummyBundle(root: root, sign: false)
        let bundle = TartBundle(url: dummy.url)
        let identity = try #require(bundle.identity)
        let backend = TartBackend(bundle: bundle, storage: storage, runner: SwappingRunner(executable: bundle.executable), verifiedBundle: identity)
        await #expect(throws: TartInvocationError.self) { _ = try await backend.version() }
    }

    /// The runner refuses to launch a file that is gone or no longer executable, and that
    /// failure arrives before the child exists, so the post-launch identity check never runs. A
    /// bundle replaced in that window is a replaced runtime, not one that verified and then
    /// would not start: reporting it as the latter would say the bundle on disk passed.
    @Test func aLaunchRefusedBecauseTheExecutableChangedIsReportedAsAReplacement() async throws {
        struct RemovingRunner: ProcessRunning {
            let executable: URL
            func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
                try? FileManager.default.removeItem(at: executable)
                throw ProcessLaunchError.executableNotFound(invocation.executable.lastPathComponent)
            }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "Refused-\(UUID().uuidString)")
        let storage = try RuntimeStorage(root: root.appending(path: "state"))
        let dummy = try await DummyBundle(root: root, sign: false)
        let bundle = TartBundle(url: dummy.url)
        let identity = try #require(bundle.identity)
        let backend = TartBackend(bundle: bundle, storage: storage, runner: RemovingRunner(executable: bundle.executable), verifiedBundle: identity)
        await #expect(throws: TartInvocationError.runtimeReplaced) { _ = try await backend.version() }
    }

    @Test func versionOutputIsBoundedByRecordCount() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Records-\(UUID().uuidString)")
        let storage = try RuntimeStorage(root: root)
        let bundle = TartBundle(url: root.appending(path: "tart.app"))
        let flood = Array(repeating: "", count: TartBackend.maximumCapturedRecords + 10) + ["2.36.0"]
        let runner = FakeProcessRunner(stdout: flood, exit: ProcessExit(reason: .status(0)))
        let backend = TartBackend(bundle: bundle, storage: storage, runner: runner)
        await #expect(throws: TartInvocationError.unparseableOutput) { _ = try await backend.version() }
    }

    @Test func anEnormousInfoPlistIsRefusedBeforeItIsParsed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Bundle-\(UUID().uuidString)")
        let contents = root.appending(path: "tart.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plist = contents.appending(path: "Info.plist")
        try Data(repeating: 0x20, count: TartBundle.maximumInfoPlistBytes + 1).write(to: plist)
        let bundle = TartBundle(url: root.appending(path: "tart.app"))
        #expect(bundle.claimedVersion == nil)
        #expect(throws: TartVerificationError.infoPlistUnreadable) { try bundle.verify() }
    }

    /// The metadata of an untrusted bundle is read through one descriptor, so what is measured
    /// is what is parsed and a replacement cannot make the reader do something else.
    @Test func theInfoPlistIsReadThroughOneDescriptor() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Plist-\(UUID().uuidString)")
        let contents = root.appending(path: "tart.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plist = contents.appending(path: "Info.plist")

        // A plist that is not a regular file at all: a reader that opens by path can block on
        // one of these, so the descriptor's own kind is what decides.
        #expect(mkfifo(plist.path, 0o600) == 0)
        #expect(TartBundle.readInfoPlist(at: plist) == nil)
        try FileManager.default.removeItem(at: plist)

        // A link to a plist that would otherwise parse: the entry itself is refused.
        let real = contents.appending(path: "Real.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "x"], format: .xml, options: 0).write(to: real)
        try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: real)
        #expect(TartBundle.readInfoPlist(at: plist) == nil)
        #expect(TartBundle.readInfoPlist(at: real)?.contents["CFBundleIdentifier"] as? String == "x")
    }

    @Test func recordedReleaseFactsAreConsistent() {
        #expect(TartRelease.version.description == "2.36" || TartVersion(parsing: TartPin.releaseTag) == TartRelease.version)
        #expect(TartRelease.archiveSHA256.count == 64)
        #expect(TartRelease.codeRequirement.contains("9M2P8L4D89"))
        #expect(TartRelease.codeRequirement.contains("com.github.cirruslabs.tart"))
        #expect(TartRelease.downloadURL.absoluteString.hasSuffix("/2.36.0/tart.tar.gz"))
    }

    @Test func locateFindsOnlyTheExpectedDirectory() throws {
        let storage = try RuntimeStorage(root: root.appending(path: "storage"))
        #expect(TartBundle.locate(in: storage) == nil)
        let expected = TartBundle.expectedLocation(in: storage)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(TartBundle.locate(in: storage)?.url == expected)
        #expect(expected.path.hasSuffix("/runtime/2.36.0/tart.app"))
    }

    @Test func missingBundleAndPlistAreReported() throws {
        #expect(throws: TartVerificationError.bundleMissing(path: root.appending(path: "nope.app").path)) {
            try TartBundle(url: root.appending(path: "nope.app")).verify()
        }
        let empty = root.appending(path: "empty/tart.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(throws: TartVerificationError.infoPlistUnreadable) { try TartBundle(url: empty).verify() }
    }

    @Test func identifierAndVersionMismatchesAreReported() async throws {
        let wrongID = try await DummyBundle(root: root.appending(path: "id"), identifier: "com.example.tart", sign: false)
        #expect(throws: TartVerificationError.bundleIdentifierMismatch(found: "com.example.tart")) { try TartBundle(url: wrongID.url).verify() }
        let wrongVersion = try await DummyBundle(root: root.appending(path: "version"), version: "2.35.0", sign: false)
        #expect(TartBundle(url: wrongVersion.url).claimedVersion?.description == "2.35.0", "claimed version comes from metadata, not execution")
        #expect(throws: TartVerificationError.versionMismatch(found: "2.35.0")) { try TartBundle(url: wrongVersion.url).verify() }
        let noExecutable = try await DummyBundle(root: root.appending(path: "exe"), executable: false, sign: false)
        #expect(throws: TartVerificationError.executableMissing) { try TartBundle(url: noExecutable.url).verify() }
    }

    @Test func adHocSignatureDoesNotSatisfyTheDeveloperIDRequirement() async throws {
        let adHoc = try await DummyBundle(root: root.appending(path: "adhoc"))
        do {
            _ = try TartBundle(url: adHoc.url).verify()
            Issue.record("an ad-hoc bundle must not verify")
        } catch TartVerificationError.requirementNotMet {
        } catch TartVerificationError.signatureInvalid {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func archiveDigestIsStreamedAndCompared() throws {
        let file = root.appending(path: "archive.bin")
        try Data(repeating: 0xAB, count: 3_000_000).write(to: file)
        let expected = "b2b8a3c3c30e2df3c5d31d3e5a55fc6f0d1c2c2c8fbf2b6b2ee8a6be6a4b1a6c"
        #expect(throws: TartVerificationError.digestMismatch) { try TartBundle.verifyArchiveDigest(of: file, expected: expected) }
        var hasher = SHA256Helper()
        hasher.update(Data(repeating: 0xAB, count: 3_000_000))
        try TartBundle.verifyArchiveDigest(of: file, expected: hasher.hex)
        #expect(throws: TartVerificationError.self) { try TartBundle.verifyArchiveDigest(of: root.appending(path: "missing.bin"), expected: hasher.hex) }
        let directory = root.appending(path: "dir.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(throws: TartVerificationError.self) { try TartBundle.verifyArchiveDigest(of: directory, expected: hasher.hex) }
    }

    @Test func versionRunsTartWithOnlyTartHomeAndParsesStrictly() async throws {
        let storage = try RuntimeStorage(root: root.appending(path: "storage2"))
        let bundle = TartBundle(url: root.appending(path: "any/tart.app"))
        let runner = FakeProcessRunner(stdout: ["2.36.0"], exit: ProcessExit(reason: .status(0)))
        let backend = TartBackend(bundle: bundle, storage: storage, runner: runner)
        #expect(try await backend.version() == TartPin.version)
        let invocation = try #require(await runner.invocations.first)
        #expect(invocation.executable == bundle.executable)
        #expect(invocation.arguments == ["--version"])
        #expect(invocation.environment == ["TART_HOME": storage.tartHome.path])

        let garbage = TartBackend(bundle: bundle, storage: storage, runner: FakeProcessRunner(stdout: ["2.36"], exit: ProcessExit(reason: .status(0))))
        await #expect(throws: TartInvocationError.unparseableOutput) { try await garbage.version() }
        // Joining the records and splitting again would drop these blanks and read the drifted
        // output as the pin; one line means one record.
        let padded = TartBackend(bundle: bundle, storage: storage, runner: FakeProcessRunner(stdout: ["", "2.36.0", ""], exit: ProcessExit(reason: .status(0))))
        await #expect(throws: TartInvocationError.unparseableOutput) { try await padded.version() }
        let failing = TartBackend(bundle: bundle, storage: storage, runner: FakeProcessRunner(stderr: ["the specified VM \"x\" does not exist"], exit: ProcessExit(reason: .status(2))))
        await #expect(throws: TartInvocationError.failed(.vmNotFound)) { try await failing.version() }
    }
}

import CryptoKit
struct SHA256Helper {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    var hex: String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
