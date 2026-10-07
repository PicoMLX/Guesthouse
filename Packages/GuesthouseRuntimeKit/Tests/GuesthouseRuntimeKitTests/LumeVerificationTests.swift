import CryptoKit
import Darwin
import Foundation
import GuesthouseCore
import Security
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct LumeVerificationTests {
    @Test(arguments: [
        ("CFBundleIdentifier", "private-untrusted-identifier", LumeVerificationError.bundleIdentifierMismatch),
        ("CFBundleShortVersionString", "private-untrusted-version", .versionMismatch),
        ("CFBundleShortVersionString", "0.5.3.0", .versionMismatch),
        ("CFBundleShortVersionString", "00.5.3", .versionMismatch),
        ("CFBundleExecutable", "private-untrusted-executable", .executableNameMismatch),
    ])
    func metadataRefusalsDoNotRetainDiscoveredText(_ sample: (String, String, LumeVerificationError)) throws {
        let f = try Fixture()
        try f.metadata(changing: sample.0, to: sample.1)
        #expect(throws: sample.2) { _ = try f.bundle.verify() }
        #expect(!sample.2.localizedDescription.contains("private-untrusted"))
        #expect(!String(describing: sample.2).contains("private-untrusted"))
    }

    @Test(arguments: [false, true]) func unreadableAndOversizedMetadataAreBounded(_ oversized: Bool) throws {
        let f = try Fixture()
        try Data(repeating: 0xff, count: oversized ? (1 << 20) + 1 : 5).write(to: f.bundle.infoPlist)
        #expect(throws: LumeVerificationError.infoPlistUnreadable) { _ = try f.bundle.verify() }
    }

    @Test(arguments: [false, true]) func missingAndLinkedAppsHaveDifferentRefusals(_ linked: Bool) throws {
        let f = try Fixture()
        let absent = f.base.appending(path: "absent.app")
        if linked { try FileManager.default.createSymbolicLink(at: absent, withDestinationURL: f.base.appending(path: "missing")) }
        #expect(throws: linked ? LumeVerificationError.insecureBundleLayout : .bundleMissing) {
            _ = try LumeBundle(url: absent).verify()
        }
    }

    @Test func nonExecutableAndLinkedLaunchFilesNeverReachSignatureAcceptance() throws {
        let f = try Fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.bundle.executable.path)
        #expect(throws: LumeVerificationError.executableMissing) { _ = try f.bundle.verify() }
        let preserved = f.base.appending(path: "preserved-executable")
        try FileManager.default.moveItem(at: f.bundle.executable, to: preserved)
        try FileManager.default.createSymbolicLink(at: f.bundle.executable, withDestinationURL: preserved)
        #expect(throws: LumeVerificationError.insecureBundleLayout) { _ = try f.bundle.verify() }
        #expect(FileManager.default.fileExists(atPath: preserved.path))
    }

    @Test func adHocCodeCannotSatisfyTheRetainedDeveloperIDRequirement() async throws {
        let f = try Fixture()
        try await sign(f.bundle.url, identifier: LumePin.bundleIdentifier)
        do {
            _ = try f.bundle.verify()
            Issue.record("Ad-hoc code must not satisfy the pinned trust policy.")
        } catch {
            #expect(error == .signatureInvalid || error == .requirementNotMet)
        }
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(LumePin.codeRequirement as CFString, [], &requirement) == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test func alteredNestedCodeIsRejectedByTheSignatureGate() async throws {
        let f = try Fixture()
        let helper = f.bundle.url.appending(path: "Contents/Helpers/Helper.app")
        let contents = helper.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: contents.appending(path: "MacOS/Helper"))
        let resource = contents.appending(path: "Resources/value.txt")
        try Data("before".utf8).write(to: resource)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.guesthouse.fixture.helper",
            "CFBundleExecutable": "Helper", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try await sign(helper, identifier: "com.guesthouse.fixture.helper")
        try await sign(f.bundle.url, identifier: LumePin.bundleIdentifier)
        try Data("changed".utf8).write(to: resource)
        var staticCode: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(f.bundle.url as CFURL, [], &staticCode) == errSecSuccess)
        let code = try #require(staticCode)
        let shallow = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        #expect(SecStaticCodeCheckValidityWithErrors(code, shallow, nil, nil) == errSecSuccess)
        #expect(throws: LumeVerificationError.signatureInvalid) { _ = try f.bundle.verify() }
    }

    @Test func streamingDigestRefusesMismatchAndUnsafeFiles() throws {
        let f = try Fixture(), archive = f.base.appending(path: "archive.bin")
        let data = Data(repeating: 0x7f, count: 2 * 1024 * 1024 + 19)
        try data.write(to: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try LumeBundle.verifyArchiveDigest(of: archive, expected: digest.uppercased())
        #expect(throws: LumeVerificationError.digestMismatch) { try LumeBundle.verifyArchiveDigest(of: archive) }
        #expect(throws: LumeVerificationError.digestMismatch) { try LumeBundle.verifyArchiveDigest(of: archive, expected: "wrong") }
        for file in [f.base, f.base.appending(path: "absent")] {
            #expect(throws: LumeVerificationError.archiveUnreadable) { try LumeBundle.verifyArchiveDigest(of: file) }
        }
        let link = f.base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        #expect(throws: LumeVerificationError.archiveUnreadable) { try LumeBundle.verifyArchiveDigest(of: link, expected: digest) }
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(atOffset: 128 * 1024 * 1024 + 1)
        try handle.close()
        #expect(throws: LumeVerificationError.archiveUnreadable) { try LumeBundle.verifyArchiveDigest(of: archive) }
    }

    private func sign(_ bundle: URL, identifier: String) async throws {
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", "--identifier", identifier, bundle.path], timeout: .seconds(30)))
        let report = try await run.waitForExit()
        #expect(report.childExit == .success(.status(0)))
        #expect(!report.timedOut && !report.canceled && !report.terminationRefused)
        _ = await run.takeOutput() // Fixture tool output is discarded, never diagnostic data.
    }

    private final class Fixture: Sendable {
        let base: URL
        let bundle: LumeBundle
        init() throws {
            var template = Array("/private/tmp/guesthouse-lume-verification-XXXXXX".utf8CString)
            let name = try #require(mkdtemp(&template))
            base = URL(fileURLWithPath: String(cString: name))
            let storage = try RuntimeStorage(root: base.appending(path: "Guesthouse"))
            bundle = LumeBundle(url: try LumeBundle.expectedLocation(in: storage))
            try FileManager.default.createDirectory(at: bundle.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: bundle.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: bundle.executable)
            try metadata()
        }
        deinit { try? FileManager.default.removeItem(at: base) } // Only this private fixture.
        func metadata(changing key: String? = nil, to value: String = "") throws {
            var fields = ["CFBundleIdentifier": LumePin.bundleIdentifier, "CFBundleShortVersionString": LumePin.version.description,
                          "CFBundleExecutable": LumePin.executableName, "CFBundlePackageType": "APPL"]
            if let key { fields[key] = value }
            try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0).write(to: bundle.infoPlist)
        }
    }
}
