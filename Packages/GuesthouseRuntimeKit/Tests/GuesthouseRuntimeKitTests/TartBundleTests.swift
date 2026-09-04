import Foundation
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
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
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

    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    @Test func aRuntimeReplacedAfterVerificationIsNotRun() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Verified-\(UUID().uuidString)")
        let executable = root.appending(path: "tart.app/Contents/MacOS/tart")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let bundle = TartBundle(url: root.appending(path: "tart.app"))
        let storage = try RuntimeStorage(root: root.appending(path: "state"))
        let runner = FakeProcessRunner(stdout: ["2.36.0"], exit: ProcessExit(reason: .status(0)))
        // A link is not a regular file, so it has no identity to bind to: the launch is
        // refused rather than trusted.
        let backend = TartBackend(bundle: bundle, storage: storage, runner: runner, verifiedExecutable: TartBundle.ExecutableIdentity(device: 1, inode: 2, size: 3, modified: timespec()))
        await #expect(throws: TartInvocationError.self) { _ = try await backend.version() }
        #expect(await runner.invocations.isEmpty, "nothing was launched")
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
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appending(path: "Info.plist")
        try Data(repeating: 0x20, count: TartBundle.maximumInfoPlistBytes + 1).write(to: plist)
        let bundle = TartBundle(url: root.appending(path: "tart.app"))
        #expect(bundle.claimedVersion == nil)
        #expect(throws: TartVerificationError.infoPlistUnreadable) { try bundle.verify() }
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
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        #expect(TartBundle.locate(in: storage)?.url == expected)
        #expect(expected.path.hasSuffix("/runtime/2.36.0/tart.app"))
    }

    @Test func missingBundleAndPlistAreReported() throws {
        #expect(throws: TartVerificationError.bundleMissing(path: root.appending(path: "nope.app").path)) {
            try TartBundle(url: root.appending(path: "nope.app")).verify()
        }
        let empty = root.appending(path: "empty/tart.app")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
