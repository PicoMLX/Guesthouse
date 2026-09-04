import Foundation

/// A Git branch name that satisfies the parts of `git check-ref-format` that matter here.
public struct BranchName: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Git's files backend writes `refs/heads/<name>.lock`, so a component longer than this
    /// cannot be created on a file system with 255-byte names.
    public static let maximumComponentBytes = 250
    /// Git stores a branch as `.git/refs/heads/<name>` and locks it at `<that>.lock`, which
    /// must fit macOS's 1024-byte pathname limit with room for the repository's own path.
    public static let maximumTotalBytes = 512

    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", name != "HEAD", !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.contains(".."), !name.contains("@{"), !name.contains("//")
        else { return false }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            if " ~^:?*[\\".unicodeScalars.contains(scalar) { return false }
            // Display controls could make the confirmation read differently from the ref.
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: break
            }
        }
        guard name.utf8.count <= maximumTotalBytes else { return false }
        // The `.lock` suffix is matched without regard to case: Git only documents the exact
        // spelling, but on the guest's case-insensitive file system `main.LOCK` still aliases
        // the `refs/heads/main.lock` file Git writes while updating `main`.
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.hasPrefix(".") && !$0.lowercased().hasSuffix(".lock") && $0.utf8.count <= maximumComponentBytes
        }
    }

    /// Identity for collision checks. Case is folded because the guest file system folds it, and
    /// the composition of accented characters because the file system treats canonically
    /// equivalent spellings as one loose-ref path.
    public var identity: String { rawValue.precomposedStringWithCanonicalMapping.lowercased() }

    /// Whether one name is a slash-component prefix of the other, which Git cannot store as
    /// two refs (`release` and `release/feature`), or the two are the same name in another case.
    public func collides(with other: BranchName) -> Bool {
        let mine = identity, theirs = other.identity
        return mine == theirs || mine.hasPrefix(theirs + "/") || theirs.hasPrefix(mine + "/")
    }
}

extension BranchName: Codable {
    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let name = BranchName(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a valid branch name: \(string)"))
        }
        self = name
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A single path component safe to use as a directory name on the guest: 1 to 64 characters
/// from letters, digits, `.`, `_`, and `-`, not starting with `.`.
public struct DirectoryName: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    static func isValid(_ name: String) -> Bool {
        guard (1...64).contains(name.count), !name.hasPrefix(".") else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// A deterministic safe name derived from a repository name that is not itself valid: a
    /// leading dot is dropped and the name is cut to the limit, so nothing silently becomes
    /// a constant that could collide with another repository.
    public static func derived(from repositoryName: String) -> DirectoryName {
        if let direct = DirectoryName(repositoryName) { return direct }
        var trimmed = String(repositoryName.drop(while: { $0 == "." }).prefix(64))
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        if let name = DirectoryName(trimmed) { return name }
        let digest = repositoryName.unicodeScalars.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1.value)) &* 1_099_511_628_211 }
        return DirectoryName("repo-\(String(digest, radix: 16))")!
    }

    /// Case-insensitive identity, because the guest file system usually is.
    public var identity: String { rawValue.lowercased() }
}

extension DirectoryName: Codable {
    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let name = DirectoryName(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a safe directory name: \(string)"))
        }
        self = name
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A 40-character lowercase SHA-1 commit identifier.
public struct CommitSHA: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    static let nullObjectID = String(repeating: "0", count: 40)

    public init?(_ rawValue: String) {
        let lowered = rawValue.lowercased()
        // ASCII hexadecimal only: `Character.isHexDigit` also accepts full-width digits.
        guard lowered.count == 40, lowered.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        // Git reserves all zeroes as the null object ID, which names the absence of a commit.
        // Recording it as a base would defer the failure to the publish flow, which cannot
        // inspect it or compute a change range from it.
        guard lowered != Self.nullObjectID else { return nil }
        self.rawValue = lowered
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let sha = CommitSHA(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a commit SHA: \(string)"))
        }
        self = sha
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
