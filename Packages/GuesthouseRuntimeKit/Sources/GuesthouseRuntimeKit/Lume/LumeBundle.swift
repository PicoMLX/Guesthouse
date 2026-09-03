import CryptoKit
import Darwin
import Foundation
import GuesthouseCore
import Security

public enum LumeVerificationError: Error, Hashable, Sendable {
    case bundleMissing(path: String)
    case insecureBundleLayout
    case infoPlistUnreadable
    case bundleIdentifierMismatch(found: SanitizedText)
    case versionMismatch(found: SanitizedText)
    case executableNameMismatch(found: SanitizedText)
    case executableMissing
    case executableUnreadable
    case executableDigestMismatch
    case signatureInvalid(status: Int32)
    case requirementNotMet(status: Int32)
    case codeDirectoryHashMismatch(found: SanitizedText)
    case teamIdentifierMismatch(found: SanitizedText)
    case signingIdentifierMismatch(found: SanitizedText)
    case entitlementMissing(String)
    case archiveUnreadable
    case digestMismatch

    /// Safe, actionable fallback for direct RuntimeKit callers. The runtime service translates
    /// these failures into the smaller public XPC error vocabulary.
    public var userMessage: String {
        switch self {
        case .bundleMissing:
            "The tested Lume runtime is missing from Guesthouse's private runtime folder."
        case .insecureBundleLayout:
            "The Lume runtime contains an unexpected link or file layout and cannot be trusted."
        case .infoPlistUnreadable, .bundleIdentifierMismatch, .versionMismatch, .executableNameMismatch:
            "The installed Lume runtime does not match the tested app metadata."
        case .executableMissing, .executableUnreadable, .executableDigestMismatch:
            "The installed Lume executable is missing, unreadable, or differs from the tested release."
        case .signatureInvalid, .requirementNotMet, .codeDirectoryHashMismatch,
             .teamIdentifierMismatch, .signingIdentifierMismatch, .entitlementMissing:
            "The installed Lume runtime does not have the tested code-signing identity and capabilities."
        case .archiveUnreadable:
            "The downloaded Lume archive cannot be read."
        case .digestMismatch:
            "The downloaded Lume archive differs from the tested release."
        }
    }

    public var recoveryActions: [RecoveryAction] { [.repair(.runtime), .cancel] }

    public var errorDescription: String? { userMessage }
}

extension LumeVerificationError: LocalizedError {}

/// Snapshot returned after pinned static verification. This is deliberately not durable launch
/// authorization: RuntimeKit must coordinate runtime replacement and reverify at the launch
/// boundary. The executable URL stays internal so clients cannot treat this token as permission
/// to launch it themselves.
public struct VerifiedLumeBundle: Hashable, Sendable {
    let bundle: LumeBundle
    public let version: SemanticVersion
    public let teamIdentifier: String
    public let signingIdentifier: String

    init(bundle: LumeBundle, version: SemanticVersion, teamIdentifier: String, signingIdentifier: String) {
        self.bundle = bundle
        self.version = version
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }

    var executable: URL { bundle.executable }
}

/// A Lume app on disk. Metadata is untrusted until `verify()` succeeds; callers must never
/// execute `executable` first (MVP-PLAN.md §3, process and trust boundaries).
public struct LumeBundle: Hashable, Sendable {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    var executable: URL { url.appending(path: "Contents/MacOS/\(LumePin.executableName)") }
    private var infoPlist: URL { url.appending(path: "Contents/Info.plist") }

    static func expectedLocation(in storage: RuntimeStorage) -> URL {
        storage.url(for: .runtime).appending(path: LumePin.releaseTag).appending(path: LumePin.bundleName)
    }

    public static func locate(in storage: RuntimeStorage) -> LumeBundle? {
        let runtimeRoot = storage.url(for: .runtime)
        let release = runtimeRoot.appending(path: LumePin.releaseTag)
        let url = expectedLocation(in: storage)
        // Recheck every app-managed component: any could have been replaced after storage
        // initialization. System aliases above `storage.root` are deliberately irrelevant.
        guard (try? RuntimeStorage.verify(storage.root)) != nil,
              (try? RuntimeStorage.verify(runtimeRoot)) != nil,
              Self.isUnlinkedItem(release, kind: S_IFDIR),
              Self.isUnlinkedItem(url, kind: S_IFDIR)
        else { return nil }
        return LumeBundle(url: url)
    }

    public func verify() throws(LumeVerificationError) -> VerifiedLumeBundle {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .bundleMissing(path: url.path)
        }
        guard Self.isUnlinkedItem(url, kind: S_IFDIR),
              Self.isUnlinkedItem(url.appending(path: "Contents"), kind: S_IFDIR),
              Self.isUnlinkedItem(url.appending(path: "Contents/MacOS"), kind: S_IFDIR),
              Self.isUnlinkedItem(infoPlist, kind: S_IFREG),
              Self.isUnlinkedItem(executable, kind: S_IFREG)
        else { throw .insecureBundleLayout }
        guard let values = infoDictionary else { throw .infoPlistUnreadable }
        let identifier = values["CFBundleIdentifier"] as? String ?? ""
        guard identifier == LumePin.bundleIdentifier else {
            throw .bundleIdentifierMismatch(found: SanitizedText(identifier, limit: 80))
        }
        let versionText = values["CFBundleShortVersionString"] as? String ?? ""
        guard let version = SemanticVersion(versionText), version == LumePin.version else {
            throw .versionMismatch(found: SanitizedText(versionText, limit: 40))
        }
        let executableName = values["CFBundleExecutable"] as? String ?? ""
        guard executableName == LumePin.executableName else {
            throw .executableNameMismatch(found: SanitizedText(executableName, limit: 80))
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw .executableMissing }

        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let code = staticCode else { throw .signatureInvalid(status: created) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let validity = SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil)
        guard validity == errSecSuccess else { throw .signatureInvalid(status: validity) }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(LumePin.codeRequirement as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else { throw .requirementNotMet(status: requirementStatus) }
        let satisfied = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil)
        guard satisfied == errSecSuccess else { throw .requirementNotMet(status: satisfied) }
        guard try Self.sha256(of: executable, unreadable: .executableUnreadable) == LumePin.executableSHA256 else {
            throw .executableDigestMismatch
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signing = information as? [String: Any]
        else { throw .signatureInvalid(status: errSecInternalError) }
        let codeDirectoryHash = (signing[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
        guard codeDirectoryHash == LumePin.codeDirectoryHash else {
            throw .codeDirectoryHashMismatch(found: SanitizedText(codeDirectoryHash, limit: 64))
        }
        let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for name in LumePin.requiredEntitlements where entitlements[name] as? Bool != true {
            throw .entitlementMissing(name)
        }
        let teamIdentifier = signing[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        guard teamIdentifier == LumePin.teamIdentifier else {
            throw .teamIdentifierMismatch(found: SanitizedText(teamIdentifier, limit: 40))
        }
        let signingIdentifier = signing[kSecCodeInfoIdentifier as String] as? String ?? ""
        guard signingIdentifier == LumePin.bundleIdentifier else {
            throw .signingIdentifierMismatch(found: SanitizedText(signingIdentifier, limit: 80))
        }
        return VerifiedLumeBundle(
            bundle: self,
            version: version,
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier
        )
    }

    public static func verifyArchiveDigest(of file: URL, expected: String = LumePin.archiveSHA256) throws(LumeVerificationError) {
        let digest = try sha256(of: file, unreadable: .archiveUnreadable)
        guard digest == expected.lowercased() else { throw .digestMismatch }
    }

    private static func sha256(of file: URL, unreadable: LumeVerificationError) throws(LumeVerificationError) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw unreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) }
            catch { throw unreadable }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var infoDictionary: [String: Any]? {
        guard Self.isUnlinkedItem(infoPlist, kind: S_IFREG),
              let handle = try? FileHandle(forReadingFrom: infoPlist)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: (1 << 20) + 1),
              data.count <= 1 << 20,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return values
    }

    /// `lstat` inspects the item itself, rather than silently following a final symlink.
    private static func isUnlinkedItem(_ url: URL, kind: mode_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == kind
    }
}
