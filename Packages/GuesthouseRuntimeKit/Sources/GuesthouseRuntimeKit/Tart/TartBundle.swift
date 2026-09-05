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
    /// The bundle changed while the checks were running, so what passed them is not what is on
    /// disk now: another `tart.app`, another `Info.plist`, or another executable.
    case bundleReplaced
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
    /// The bundle that passed the checks. Verification records it rather than leaving the
    /// caller to read it again: a second read can find a link, or nothing at all, where the
    /// verified bundle was, and a caller that treats a missing identity as "no check needed"
    /// would then launch whatever is there.
    public let bundle: TartBundle.BundleIdentity
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
        guard let plist = Self.readInfoPlist(at: infoPlist)?.contents, let text = plist["CFBundleShortVersionString"] as? String else { return nil }
        return TartVersion(parsing: text)
    }

    /// The largest `Info.plist` this reads. A real one is a few kilobytes; anything larger
    /// is refused rather than parsed.
    static let maximumInfoPlistBytes = 256 << 10

    /// The bundle is untrusted until its signature is checked, so its metadata is opened once
    /// and read through that descriptor. Checking a file's size and then reading it by path
    /// reopens it, and a bundle that grows or replaces `Info.plist` in between would be read
    /// whole; a replacement that is not a regular file could block the read instead. One byte
    /// past the cap is read, so a file over it is refused rather than parsed.
    ///
    /// The identity comes from that same descriptor, so what verification binds is the file it
    /// parsed and not whatever the path names a moment later.
    static func readInfoPlist(at url: URL) -> (contents: [String: Any], identity: FileIdentity)? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: maximumInfoPlistBytes + 1)
        var filled = 0
        while filled < buffer.count {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress! + filled, bytes.count - filled)
            }
            if count < 0 {
                guard errno == EINTR else { return nil }
                continue
            }
            if count == 0 { break }
            filled += count
        }
        guard filled <= maximumInfoPlistBytes else { return nil }
        let data = Data(buffer[..<filled])
        guard let contents = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return (contents, FileIdentity(info))
    }

    /// What one file was when it passed verification: the same file, unchanged. A launch
    /// compares these against what is on disk, so a bundle replaced after verification is
    /// never executed.
    public struct FileIdentity: Hashable, Sendable {
        public let device: UInt64
        public let inode: UInt64
        public let size: Int64
        public let modified: timespec
        /// The inode's change time. A process may set modification time back to whatever it
        /// was, so a same-sized binary written over the verified one leaves every other field
        /// here untouched; the change time records each write to the inode and nothing in user
        /// space can reset it.
        public let changed: timespec

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(device); hasher.combine(inode); hasher.combine(size)
            hasher.combine(modified.tv_sec); hasher.combine(modified.tv_nsec)
            hasher.combine(changed.tv_sec); hasher.combine(changed.tv_nsec)
        }

        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = info.st_mtimespec
            changed = info.st_ctimespec
        }

        public init(device: UInt64, inode: UInt64, size: Int64, modified: timespec, changed: timespec) {
            self.device = device
            self.inode = inode
            self.size = size
            self.modified = modified
            self.changed = changed
        }
    }

    /// What the bundle was when it passed verification.
    ///
    /// The executable alone is not the bundle. `Contents/MacOS/tart` can be hard-linked into a
    /// bundle of somebody else's making, and its device, inode, size, and times are then still
    /// exactly the verified ones while the `Info.plist`, the resources, and the nested code
    /// around it belong to a bundle that passed nothing. What is bound is therefore the
    /// directory, the `Info.plist` the checks read, and the executable together — the complete
    /// official bundle MVP-PLAN.md §4 requires, not one file out of it.
    public struct BundleIdentity: Hashable, Sendable {
        /// The `.app` directory itself, by device and inode alone: a bundle swapped for
        /// another is a different directory, while the metadata macOS writes on a bundle it
        /// has seen — a quarantine or provenance attribute — changes times without changing
        /// the object and must not read as a replacement.
        public let directoryDevice: UInt64
        public let directoryInode: UInt64
        public let infoPlist: FileIdentity
        public let executable: FileIdentity

        public init(directoryDevice: UInt64, directoryInode: UInt64, infoPlist: FileIdentity, executable: FileIdentity) {
            self.directoryDevice = directoryDevice
            self.directoryInode = directoryInode
            self.infoPlist = infoPlist
            self.executable = executable
        }
    }

    /// The executable's identity now, without following links, or `nil` if it cannot be read.
    public var executableIdentity: FileIdentity? { Self.regularFileIdentity(of: executable) }

    /// The identity of one regular file, without following links: a link, a directory, or
    /// anything else where a file belongs has no identity to bind to.
    static func regularFileIdentity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(info)
    }

    /// The whole bundle's identity now, or `nil` when any part of it is not what it has to be.
    public var identity: BundleIdentity? {
        guard let plist = Self.regularFileIdentity(of: infoPlist) else { return nil }
        return identity(infoPlist: plist)
    }

    /// The same, with the `Info.plist` identity supplied by the read that parsed it rather
    /// than by a second look at the path.
    func identity(infoPlist plist: FileIdentity) -> BundleIdentity? {
        var directory = stat()
        guard lstat(url.path, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR,
              let executable = executableIdentity
        else { return nil }
        return BundleIdentity(
            directoryDevice: UInt64(directory.st_dev),
            directoryInode: UInt64(directory.st_ino),
            infoPlist: plist,
            executable: executable
        )
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
        guard let (plist, plistWhenRead) = Self.readInfoPlist(at: infoPlist) else { throw .infoPlistUnreadable }
        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        guard identifier == TartRelease.signingIdentifier else { throw .bundleIdentifierMismatch(found: Self.describe(identifier)) }
        let versionText = plist["CFBundleShortVersionString"] as? String ?? ""
        guard let version = TartVersion(parsing: versionText), version == TartRelease.version else {
            throw .versionMismatch(found: Self.describe(versionText))
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw .executableMissing }
        // The identity is taken before the checks below and compared with the one taken after
        // them. Reading it only at the end would record whatever is there once they are done,
        // so a bundle replaced while they ran would be launched as the one that passed them
        // (MVP-PLAN.md §4). It is the whole bundle, not the executable alone: a replacement
        // that hard-links the verified executable into place leaves that file's identity
        // untouched while everything the signature also covers is another bundle's.
        guard let bundleWhenChecked = identity(infoPlist: plistWhenRead) else { throw .executableMissing }

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
        // Recorded here rather than by the caller afterwards, and required: a bundle that
        // cannot be identified the moment it passed is one nothing may be launched from. It has
        // to be the bundle the checks above ran on, or nothing was verified.
        guard let bundle = identity else { throw .executableMissing }
        guard bundle == bundleWhenChecked else { throw .bundleReplaced }
        return TartVerification(version: version, teamIdentifier: team, signingIdentifier: identifier, bundle: bundle)
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
