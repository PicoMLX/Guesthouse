import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct WorkspaceIdentifierTests {
    @Test(arguments: ["main", "feature/123-thing", "release-2.0", "user/topic.v2", "a/b/c", "feature/HEAD", "feature/é"])
    func acceptsSupportedBranchNames(_ value: String) throws {
        let branch = try #require(BranchName(value))
        #expect(try JSONDecoder().decode(BranchName.self, from: JSONEncoder().encode(branch)) == branch)
    }
    @Test(arguments: ["", "-x", "/x", "x/", "x.", "x.lock", "x.LOCK", "a..b", "a@{b", "a//b", "@", "HEAD", "with space", "tab\tx", "tilde~", "caret^", "colon:", "quest?", "star*", "brack[", "back\\", ".hidden", "a/.b", "a/b.lock", "a\u{202E}", "a\u{2028}b", "a\u{FFFE}"])
    func rejectsUnsafeBranchNamesIncludingDecodedInput(_ value: String) throws {
        #expect(BranchName(value) == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BranchName.self, from: JSONEncoder().encode(value)) }
    }
    @Test func branchBoundsUseBytesAndWholeRefLength() {
        let component = String(repeating: "a", count: 250)
        #expect(BranchName(component) != nil && BranchName(component + "a") == nil)
        #expect(BranchName(String(repeating: "é", count: 126)) == nil)
        #expect(BranchName([component, component].joined(separator: "/")) != nil)
        #expect(BranchName([component, component, component].joined(separator: "/")) == nil)
    }
    @Test func branchCollisionsIncludeUnicodeCaseCompositionAndPathPrefixes() throws {
        for (a, b) in [("main", "MAIN"), ("release", "release/feature"), ("feature/Σ", "feature/ς"), ("feature/é", "feature/e\u{301}")] {
            let first = try #require(BranchName(a)), second = try #require(BranchName(b))
            #expect(first.collides(with: second) && second.collides(with: first))
        }
        #expect(BranchName("release")?.collides(with: try #require(BranchName("released"))) == false)
    }
    @Test func directoryNamesAreBoundedSingleComponentsAndDerivedNamesNeedCollisionChecks() throws {
        for good in ["MyApp", "feature-123", "a.b_c", String(repeating: "x", count: 64)] {
            let name = try #require(DirectoryName(good))
            #expect(try JSONDecoder().decode(DirectoryName.self, from: JSONEncoder().encode(name)) == name)
        }
        for bad in ["", ".", "..", ".hidden", "a/b", "a b", "é", String(repeating: "x", count: 65), "a\nb"] {
            #expect(DirectoryName(bad) == nil)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(DirectoryName.self, from: JSONEncoder().encode(bad)) }
        }
        #expect(DirectoryName("MyApp")?.identity == DirectoryName("myapp")?.identity)
        #expect(DirectoryName.derived(from: ".github").rawValue == "github")
        #expect(DirectoryName.derived(from: "...").rawValue.hasPrefix("repo-"))
        #expect(DirectoryName.derived(from: "...") == DirectoryName.derived(from: "..."))
        #expect(DirectoryName.derived(from: String(repeating: "r", count: 65)).rawValue.count == 64)
    }
    @Test func commitIdentifiersAreNonzeroASCIIHexAndRoundTrip() throws {
        let sha = try #require(CommitSHA(String(repeating: "A", count: 40)))
        #expect(sha.rawValue == String(repeating: "a", count: 40))
        #expect(try JSONDecoder().decode(CommitSHA.self, from: JSONEncoder().encode(sha)) == sha)
        for invalid in ["abc", String(repeating: "0", count: 40), String(repeating: "Ｆ", count: 40), String(repeating: "g", count: 40)] {
            #expect(CommitSHA(invalid) == nil)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(CommitSHA.self, from: JSONEncoder().encode(invalid)) }
        }
    }
    @Test func decoderFailureDescriptionsDoNotEchoUntrustedInput() throws {
        let marker = "synthetic secret value"
        let bytes = try JSONEncoder().encode(marker)
        do { _ = try JSONDecoder().decode(BranchName.self, from: bytes); Issue.record("Expected rejection") }
        catch DecodingError.dataCorrupted(let context) { #expect(!context.debugDescription.contains(marker)) }
        do { _ = try JSONDecoder().decode(DirectoryName.self, from: bytes); Issue.record("Expected rejection") }
        catch DecodingError.dataCorrupted(let context) { #expect(!context.debugDescription.contains(marker)) }
        do { _ = try JSONDecoder().decode(CommitSHA.self, from: bytes); Issue.record("Expected rejection") }
        catch DecodingError.dataCorrupted(let context) { #expect(!context.debugDescription.contains(marker)) }
    }
}
