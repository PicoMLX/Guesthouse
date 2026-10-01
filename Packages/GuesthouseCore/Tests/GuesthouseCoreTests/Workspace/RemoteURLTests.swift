import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RemoteURLTests {
    @Test(arguments: ["https://github.com/PicoMLX/Guesthouse.git", "https://github.com/PicoMLX/Guesthouse", "git@github.com:PicoMLX/Guesthouse.git", "ssh://git@github.com/PicoMLX/Guesthouse.git", "https://GitHub.com/PicoMLX/Guesthouse/"])
    func canonicalizesSupportedForms(_ value: String) throws {
        let remote = try #require(RemoteURL(value))
        #expect(remote.canonical == "https://github.com/PicoMLX/Guesthouse")
        #expect(remote.owner == "PicoMLX" && remote.name == "Guesthouse" && remote.isSupportedHost)
        #expect(RemoteURL(remote.canonical) == remote)
        #expect(try JSONDecoder().decode(RemoteURL.self, from: JSONEncoder().encode(remote)) == remote)
    }
    @Test func githubIdentityIgnoresCaseButUnsupportedHostsRetainPathCase() throws {
        let a = try #require(RemoteURL("https://github.com/picomlx/guesthouse"))
        let b = try #require(RemoteURL("git@github.com:PicoMLX/Guesthouse.git"))
        #expect(a == b && Set([a, b]).count == 1)
        let other = try #require(RemoteURL("https://gitlab.com/Group/Project.git"))
        #expect(!other.isSupportedHost && other.canonical == "https://gitlab.com/Group/Project")
        #expect(other != RemoteURL("https://gitlab.com/group/project"))
    }
    @Test(arguments: ["", "github.com/Org/Repo", "https://github.com/Org", "https://github.com/a/b/c", "file:///tmp/repo", "https://github.com/../x", "git@github.com:Org/Repo/", "git@github.com:/Org/Repo", "git@github.com:Org//Repo", "https://github.com//Org/Repo", "https://github.com/Org/Repo//", "https://github.com/Org/foo%2Dbar", "https://github.com:8443/Org/Repo", "ssh://git@github.com:2222/Org/Repo", "http://github.com/Org/Repo", "git://github.com/Org/Repo", "ssh://someone@github.com/Org/Repo", "ssh://github.com/Org/Repo", "someone@github.com:Org/Repo", "https://github.com/Org/Repo?ref=x", "https://github.com/Org/Repo#fragment", "https://github.com/Org/Repo.git.git", "https://github.com/Org/Repo ", " https://github.com/Org/Repo", "https://github.com/my.org/Repo", "https://github.com/org--name/Repo", "https://github.com/Ｏrg/Repo"])
    func rejectsAmbiguousUnsupportedSyntaxAndNonRoundTrippableInput(_ value: String) throws {
        #expect(RemoteURL(value) == nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RemoteURL.self, from: JSONEncoder().encode(value)) }
    }
    @Test func refusesCredentialsWithoutEchoingThemInDecoderErrors() throws {
        let marker = "synthetic-private-token"
        for value in ["https://\(marker)@github.com/Org/Repo", "https://user:\(marker)@github.com/Org/Repo", "ssh://git:\(marker)@github.com/Org/Repo"] {
            #expect(RemoteURL(value) == nil)
            do { _ = try JSONDecoder().decode(RemoteURL.self, from: JSONEncoder().encode(value)); Issue.record("Expected rejection") }
            catch DecodingError.dataCorrupted(let context) { #expect(!context.debugDescription.contains(marker)) }
        }
    }
    @Test func ownerAndRepositoryComponentsHaveSeparateBoundedAlphabets() {
        #expect(RemoteURL("https://github.com/Org-Name/repo_name.v2") != nil)
        #expect(RemoteURL("https://github.com/" + String(repeating: "o", count: 39) + "/Repo") != nil)
        #expect(RemoteURL("https://github.com/" + String(repeating: "o", count: 40) + "/Repo") == nil)
        #expect(RemoteURL("https://github.com/Org/" + String(repeating: "r", count: 100)) != nil)
        #expect(RemoteURL("https://github.com/Org/" + String(repeating: "r", count: 101)) == nil)
        for owner in ["_", "-org", "org-"] { #expect(RemoteURL("https://github.com/\(owner)/Repo") == nil) }
    }
}
