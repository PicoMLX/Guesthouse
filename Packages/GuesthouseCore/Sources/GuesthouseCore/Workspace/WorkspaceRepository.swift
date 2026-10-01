import Foundation

public struct WorkspaceRepository: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable {
        case app
        case package
    }

    public var role: Role
    public var remote: RemoteURL
    /// Directory name under `repos/`. Defaults to the repository name.
    public var checkoutName: DirectoryName
    public var baseBranch: BranchName
    /// Recorded when the clone is made; `nil` until then.
    public var baseSHA: CommitSHA?
    public var taskBranch: BranchName
    /// The commit last pushed to `taskBranch`, recorded the moment the push completes.
    ///
    /// It sits beside the repository rather than inside `draftPullRequest` because a push can
    /// succeed and the pull request that follows it fail (MVP-PLAN.md §7): the reference cannot
    /// exist until GitHub has issued a number. This is last-known metadata, not permission to
    /// replay a push; an interrupted outcome still requires inspection.
    public var publishedSHA: CommitSHA?
    public var draftPullRequest: PullRequestReference?

    public init(role: Role, remote: RemoteURL, checkoutName: DirectoryName? = nil, baseBranch: BranchName, baseSHA: CommitSHA? = nil, taskBranch: BranchName, publishedSHA: CommitSHA? = nil, draftPullRequest: PullRequestReference? = nil) {
        self.role = role
        self.remote = remote
        self.checkoutName = checkoutName ?? DirectoryName.derived(from: remote.name)
        self.baseBranch = baseBranch
        self.baseSHA = baseSHA
        self.taskBranch = taskBranch
        self.publishedSHA = publishedSHA
        self.draftPullRequest = draftPullRequest
    }
}

public struct PullRequestReference: Codable, Hashable, Sendable {
    public var number: Int
    public var url: URL?

    public init(number: Int, url: URL? = nil) {
        self.number = number
        self.url = url
    }

    /// A positive number, and if a link is recorded, the HTTPS pull-request page of exactly
    /// this repository; a guest-owned manifest is never allowed to point anywhere else.
    public func isValid(for remote: RemoteURL) -> Bool {
        guard number > 0, remote.isSupportedHost else { return false }
        guard let url else { return true }
        // The route itself is a case-sensitive URL path, so only the scheme, host, owner, and
        // repository are compared without regard to case, as GitHub resolves them: a `/PULL/`
        // link does not open the recorded pull request.
        let text = url.absoluteString
        let route = "/pull/\(number)"
        guard text.hasSuffix(route) else { return false }
        return text.dropLast(route.count).lowercased() == remote.canonical.lowercased()
    }
}

/// Bounded destination fields. Syntax validity does not prove a destination exists or is
/// compatible. The manifest/runtime consumer must validate before forming a command argument.
public struct TestDestination: Codable, Hashable, Sendable {
    public var platform: String
    public var name: String?
    public var os: String?

    public init(platform: String, name: String? = nil, os: String? = nil) {
        self.platform = platform
        self.name = name
        self.os = os
    }

    public static let macOS = TestDestination(platform: "macOS")

    /// Xcode's own platform, device, and OS values are a few dozen bytes; a field beyond this
    /// names no destination, and the whole specifier stays well inside the argument the guest
    /// can pass to `xcodebuild`.
    static let maximumFieldBytes = 128
    static let maximumSpecifierBytes = 512

    /// Non-empty, bounded fields without display controls or specifier delimiters. These
    /// private metadata values are never diagnostic fields; no credential heuristics run.
    public var isValid: Bool {
        guard !platform.isEmpty, specifier.utf8.count <= Self.maximumSpecifierBytes else { return false }
        return [platform, name ?? "x", os ?? "x"].allSatisfy { value in
            !value.isEmpty && !value.contains(",") && !value.contains("=") && !WorkspaceTextRules.containsDisplayControls(value)
                && value.utf8.count <= Self.maximumFieldBytes
        }
    }

    /// The `-destination` argument value.
    public var specifier: String {
        var parts = ["platform=\(platform)"]
        if let name { parts.append("name=\(name)") }
        if let os { parts.append("OS=\(os)") }
        return parts.joined(separator: ",")
    }
}

enum WorkspaceTextRules {
    static func containsDisplayControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: true
            default: scalar.properties.isNoncharacterCodePoint
            }
        }
    }
}
