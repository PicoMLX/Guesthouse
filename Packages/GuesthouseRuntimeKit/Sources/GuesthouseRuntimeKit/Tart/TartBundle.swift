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

    /// Verifies the bundle against the pinned release: identifier and version from Info.plist,
    /// an executable, a valid Developer ID signature that satisfies the recorded team and
    /// identifier, and the virtualization entitlement.
    public func verify() throws(TartVerificationError) -> TartVerification {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .bundleMissing(path: url.path)
        }
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw .infoPlistUnreadable }
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
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else { throw .digestMismatch }
    }
}
