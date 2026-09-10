import CoreServices
import Darwin
import Foundation
import GuesthouseCore

/// Runtime-only, read-only application discovery (#12, MVP-PLAN.md §§2–3).
/// Bundle metadata is an observation, NOT signature, account or connection compatibility
/// evidence. No application path or arbitrary plist/error text leaves this probe.
public struct SystemCodexDesktopProbe: Sendable {
    // Verified from the installed application's Info.plist. Its folder/display name can
    // differ; do not assume "/Applications/Codex.app" or accept ChatGPT's com.openai.chat ID.
    static let bundleIdentifier = "com.openai.codex"
    static let maximumMetadataBytes = 128 * 1024
    static let maximumCandidates = 32

    enum Candidate: Equatable, Sendable {
        case notFound, unavailable, preferred(URL)
    }

    private let lookup: @Sendable () -> Candidate
    private let metadata: @Sendable (URL) -> Data?

    public init() {
        self.init(lookup: { Self.registeredApplication() }, metadata: { Self.readMetadata(at: $0) })
    }

    init(lookup: @escaping @Sendable () -> Candidate, metadata: @escaping @Sendable (URL) -> Data?) {
        self.lookup = lookup
        self.metadata = metadata
    }

    public func observe() -> CodexDesktopObservation {
        switch lookup() {
        case .notFound: .notFound
        case .unavailable: .unavailable
        case .preferred(let url): Self.decodeMetadata(metadata(url))
        }
    }

    static func decodeMetadata(_ data: Data?) -> CodexDesktopObservation {
        guard let data, data.count <= maximumMetadataBytes,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any],
              dictionary["CFBundleIdentifier"] as? String == bundleIdentifier else { return .unavailable }
        // An identified bundle with absent/nonconforming version text is still present.
        // Exact private connect-time identity stays in the compatibility workflow.
        let version = (dictionary["CFBundleShortVersionString"] as? String).flatMap { SemanticVersion($0) }
        let build = (dictionary["CFBundleVersion"] as? String).flatMap { SemanticVersion($0) }
        return .installed(version: version, build: build)
    }

    /// LSInfo.h documents not-found as NULL plus kLSApplicationNotFoundErr and, since
    /// macOS 10.15, sorts the preferred application first. A failed/inconsistent lookup,
    /// empty success or unreadable preferred copy is not a claim that no app is installed.
    static func candidate(urls: [URL]?, errorDomain: String?, errorCode: Int?) -> Candidate {
        if errorDomain != nil || errorCode != nil {
            return urls == nil && errorDomain == NSOSStatusErrorDomain && errorCode == Int(kLSApplicationNotFoundErr)
                ? .notFound : .unavailable
        }
        guard let urls, !urls.isEmpty, urls.count <= maximumCandidates else { return .unavailable }
        return .preferred(urls[0])
    }

    private static func registeredApplication() -> Candidate {
        var error: Unmanaged<CFError>?
        // The error-returning LaunchServices API preserves not-found versus lookup failure.
        // The SDK marks replacement as API_TO_BE_DEPRECATED, not a current removal.
        let applications = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, &error)?.takeRetainedValue()
        let failure = error?.takeRetainedValue()
        if let applications, CFArrayGetCount(applications) > maximumCandidates { return .unavailable }
        let urls = applications.flatMap { $0 as? [URL] }
        if applications != nil && urls == nil { return .unavailable }
        return candidate(urls: urls, errorDomain: failure.map { CFErrorGetDomain($0) as String },
                         errorCode: failure.map { CFErrorGetCode($0) })
    }

    /// Bound reads before plist parsing. Refuse non-regular/symlink metadata, oversize files,
    /// non-local URLs and read failures. No Bundle loading or executable launch is involved.
    static func readMetadata(at application: URL) -> Data? {
        guard application.isFileURL,
              application.host == nil || application.host == "" || application.host == "localhost",
              application.query == nil, application.fragment == nil else { return nil }
        let url = application.appendingPathComponent("Contents", isDirectory: true).appendingPathComponent("Info.plist")
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX) else { return nil }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maximumMetadataBytes) else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maximumMetadataBytes {
            let limit = min(buffer.count, maximumMetadataBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, limit) }
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }
}
