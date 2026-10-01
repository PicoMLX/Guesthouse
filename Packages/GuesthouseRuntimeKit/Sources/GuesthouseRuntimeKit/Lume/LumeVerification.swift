import CryptoKit
import Darwin
import Foundation
import GuesthouseCore
import Security

/// A static snapshot from the strict verifier, not durable launch authorization. Its initializer
/// and executable remain confined to RuntimeKit. Launch integration must rediscover/reverify
/// immediately before EACH launch while serializing every managed runtime replacement.
struct VerifiedLumeBundle: Hashable, Sendable {
    fileprivate let bundle: LumeBundle
    fileprivate let verifiedFileIdentity: LumeBundleFileIdentity
    var version: SemanticVersion { LumePin.version }
    var teamIdentifier: String { LumePin.teamIdentifier }
    var signingIdentifier: String { LumePin.bundleIdentifier }
    var executable: URL { bundle.executable }
    func matchesVerifiedFiles(in candidate: LumeBundle) -> Bool {
        candidate.url == bundle.url && candidate.fileIdentity == verifiedFileIdentity
    }
}

extension LumeBundle {
    /// Migrated #83/#86 policy for MVP-PLAN.md §3. No code execution, installer, XPC operation,
    /// production activation or signature exception. The retained 0.5.3 pin remains rejected.
    func verify() throws(LumeVerificationError) -> VerifiedLumeBundle {
        guard let path = try? StorageProtection.path(url) else { throw .insecureBundleLayout }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw errno == ENOENT ? .bundleMissing : .insecureBundleLayout
        }
        guard let snapshot = fileIdentity else { throw .insecureBundleLayout }
        let data = try Self.readMetadata(infoPlist, expected: snapshot.infoPlist)
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw .infoPlistUnreadable
        }
        guard values["CFBundleIdentifier"] as? String == LumePin.bundleIdentifier else { throw .bundleIdentifierMismatch }
        guard values["CFBundleShortVersionString"] as? String == LumePin.version.description else { throw .versionMismatch }
        guard values["CFBundleExecutable"] as? String == LumePin.executableName else { throw .executableNameMismatch }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw .executableMissing }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { throw .signatureInvalid }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess else { throw .signatureInvalid }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(LumePin.codeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess else { throw .requirementNotMet }
        guard try Self.sha256(executable, expected: snapshot.executable, unreadable: .executableUnreadable)
                == LumePin.executableSHA256 else { throw .executableDigestMismatch }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signing = information as? [String: Any] else { throw .signatureInvalid }
        guard let hash = signing[kSecCodeInfoUnique as String] as? Data,
              Self.hex(hash) == LumePin.codeDirectoryHash else { throw .codeDirectoryHashMismatch }
        guard let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              Set(entitlements.keys) == Set(LumePin.requiredEntitlements),
              LumePin.requiredEntitlements.allSatisfy({ entitlements[$0] as? Bool == true }) else { throw .entitlementMismatch }
        guard signing[kSecCodeInfoTeamIdentifier as String] as? String == LumePin.teamIdentifier else { throw .teamIdentifierMismatch }
        guard signing[kSecCodeInfoIdentifier as String] as? String == LumePin.bundleIdentifier else { throw .signingIdentifierMismatch }
        guard fileIdentity == snapshot else { throw .insecureBundleLayout }
        return VerifiedLumeBundle(bundle: self, verifiedFileIdentity: snapshot)
    }

    /// Production policy has no caller-supplied digest. The internal overload only supports
    /// deterministic digest fixtures; neither form grants bundle or process-launch authority.
    static func verifyArchiveDigest(of file: URL) throws(LumeVerificationError) {
        try verifyArchiveDigest(of: file, expected: LumePin.archiveSHA256)
    }
    static func verifyArchiveDigest(of file: URL, expected: String) throws(LumeVerificationError) {
        guard try sha256(file, unreadable: .archiveUnreadable) == expected.lowercased() else { throw .digestMismatch }
    }

    private static func openFile(_ url: URL, expected: LumeBundleFileIdentity.Item?,
                                 unreadable: LumeVerificationError) throws(LumeVerificationError) -> Int32 {
        guard let path = try? StorageProtection.path(url) else { throw unreadable }
        // O_NONBLOCK prevents opening an unexpected FIFO/device from hanging before fstat.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw unreadable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              expected == nil || LumeBundleFileIdentity.Item(info) == expected else {
            close(fd)
            throw unreadable
        }
        return fd
    }
    private static func readMetadata(_ file: URL, expected: LumeBundleFileIdentity.Item) throws(LumeVerificationError) -> Data {
        guard expected.bytes >= 0, expected.bytes <= 1 << 20 else { throw .infoPlistUnreadable }
        let fd = try openFile(file, expected: expected, unreadable: .infoPlistUnreadable)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: (1 << 20) + 1), data.count <= 1 << 20 else { throw .infoPlistUnreadable }
        return data
    }
    private static func sha256(_ file: URL, expected: LumeBundleFileIdentity.Item? = nil,
                               unreadable: LumeVerificationError) throws(LumeVerificationError) -> String {
        let fd = try openFile(file, expected: expected, unreadable: unreadable)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        let limit = 128 * 1024 * 1024
        guard fstat(fd, &before) == 0, before.st_size >= 0, before.st_size <= off_t(limit) else { throw unreadable }
        var hasher = SHA256()
        var readBytes = 0
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { throw unreadable }
            guard let chunk, !chunk.isEmpty else { break }
            guard chunk.count <= limit - readBytes else { throw unreadable }
            readBytes += chunk.count
            hasher.update(data: chunk)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, LumeBundleFileIdentity.Item(before) == LumeBundleFileIdentity.Item(after) else { throw unreadable }
        return hex(hasher.finalize())
    }
    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
