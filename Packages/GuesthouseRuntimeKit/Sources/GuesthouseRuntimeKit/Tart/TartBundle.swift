import Darwin
import CryptoKit
import Foundation
import GuesthouseCore
import Security

public enum TartVerificationError: Error, Hashable, Sendable {
    case bundleMissing(path: String)
    case infoPlistUnreadable
    case bundleIdentifierMismatch(found: String)
    case versionMismatch(found: String)
    case executableMissing
    case signatureInvalid(status: Int32)
    case requirementNotMet(status: Int32)
    case entitlementMissing(String)
    case digestMismatch
    case archiveUnreadable
}

/// What verification established about a bundle.
public struct TartVerification: Hashable, Sendable {
    public let version: TartVersion
    public let teamIdentifier: String
    public let signingIdentifier: String
}

/// A Tart.app bundle on disk and the checks that make it trustworthy to run.
public struct TartBundle: Hashable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var executable: URL { url.appending(path: "Contents/MacOS/\(TartRelease.executableName)") }
    public var infoPlist: URL { url.appending(path: "Contents/Info.plist") }

    /// The pinned release's expected location under runtime storage.
    public static func expectedLocation(in storage: RuntimeStorage) -> URL {
        storage.url(for: .runtime).appending(path: TartPin.releaseTag).appending(path: TartRelease.bundleName)
    }

    /// The pinned bundle under runtime storage, if it exists. Existence is not trust; call `verify`.
    public static func locate(in storage: RuntimeStorage) -> TartBundle? {
        let url = expectedLocation(in: storage)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return TartBundle(url: url)
    }

    /// The version the bundle claims in its Info.plist, read without executing anything.
    public var claimedVersion: TartVersion? {
        guard let plist = Self.readInfoPlist(at: infoPlist), let text = plist["CFBundleShortVersionString"] as? String else { return nil }
        return TartVersion(parsing: text)
    }

    /// The largest `Info.plist` this reads. A real one is a few kilobytes; anything larger
    /// is refused rather than parsed.
    static let maximumInfoPlistBytes = 256 << 10

    static func readInfoPlist(at url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= maximumInfoPlistBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count <= maximumInfoPlistBytes
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// What the executable was when it passed verification: the same file, unchanged. A
    /// launch compares this against the file it is about to run, so a bundle replaced after
    /// verification is never executed.
    public struct ExecutableIdentity: Hashable, Sendable {
        public let device: UInt64
        public let inode: UInt64
        public let size: Int64
        public let modified: timespec

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(device); hasher.combine(inode); hasher.combine(size)
            hasher.combine(modified.tv_sec); hasher.combine(modified.tv_nsec)
        }
    }

    /// The executable's identity now, without following links, or `nil` if it cannot be read.
    public var executableIdentity: ExecutableIdentity? {
        var info = stat()
        guard lstat(executable.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return ExecutableIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: info.st_mtimespec)
    }

    /// Verifies the bundle against the pinned release: identifier and version from Info.plist,
    /// an executable, a valid Developer ID signature that satisfies the recorded team and
    /// identifier, and the virtualization entitlement.
    public func verify() throws(TartVerificationError) -> TartVerification {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .bundleMissing(path: url.path)
        }
        // The bundle is untrusted until its signature is checked, so its metadata is read
        // under a size cap: a huge Info.plist must not exhaust the service before the check.
        guard let plist = Self.readInfoPlist(at: infoPlist) else { throw .infoPlistUnreadable }
        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        guard identifier == TartRelease.signingIdentifier else { throw .bundleIdentifierMismatch(found: Self.describe(identifier)) }
        let versionText = plist["CFBundleShortVersionString"] as? String ?? ""
        guard let version = TartVersion(parsing: versionText), version == TartRelease.version else {
            throw .versionMismatch(found: Self.describe(versionText))
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw .executableMissing }

        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let code = staticCode else { throw .signatureInvalid(status: created) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let validity = SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil)
        guard validity == errSecSuccess else { throw .signatureInvalid(status: validity) }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(TartRelease.codeRequirement as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else { throw .requirementNotMet(status: requirementStatus) }
        let satisfied = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil)
        guard satisfied == errSecSuccess else { throw .requirementNotMet(status: satisfied) }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any]
        else { throw .signatureInvalid(status: errSecInternalError) }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for entitlement in TartRelease.requiredEntitlements where entitlements[entitlement] as? Bool != true {
            throw .entitlementMissing(entitlement)
        }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        return TartVerification(version: version, teamIdentifier: team, signingIdentifier: identifier)
    }

    /// Values read from a bundle on disk are untrusted: redact, drop control characters, and
    /// bound them before they can appear in an error.
    static func describe(_ value: String) -> String {
        let cleaned = Redactor().redact(fieldValue: value).unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(cleaned.prefix(80)))
    }

    /// Streams a file through SHA-256 and compares it with the pinned digest.
    public static func verifyArchiveDigest(of fileURL: URL, expected: String = TartRelease.archiveSHA256) throws(TartVerificationError) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { throw .bundleMissing(path: fileURL.path) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                throw .archiveUnreadable
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else { throw .digestMismatch }
    }
}
