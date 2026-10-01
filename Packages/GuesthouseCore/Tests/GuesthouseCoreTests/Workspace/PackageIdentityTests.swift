import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct PackageIdentityTests {
    @Test(arguments: [
        ("https://github.com/Org/Library.git", "library"),
        ("git@github.com:Org/Library.git", "library"),
        ("ssh://git@github.com/Org/Library/", "library"),
        ("https://github.com/Org/Library.GIT", "library.git"),
        ("git@host:Name.git", "git@host:name"),
        ("/tmp/ Foo ", " foo "), ("/tmp/CaféKit", "cafékit"), ("Library", "library")
    ])
    func derivesUnixLocationIdentityWithoutRemoteCanonicalization(_ location: String, _ expected: String) {
        #expect(PackageIdentity(location: location)?.rawValue == expected)
    }

    @Test(arguments: ["", ".git", ".", "..", "/", "https://github.com/Org/Library//", "a\n", "a\u{202E}b", "a\u{FFFE}b"])
    func rejectsUnusableOrDisplayControlledLocations(_ location: String) {
        #expect(PackageIdentity(location: location) == nil)
    }

    @Test func remoteAndCheckoutIdentityUseTheirOwnInputs() throws {
        let remote = try #require(RemoteURL("https://github.com/Org/Library"))
        #expect(PackageIdentity(remote: remote).rawValue == "library")
        let checkout = try #require(DirectoryName("Library.git")), upper = try #require(DirectoryName("Library.GIT"))
        #expect(PackageIdentity(checkoutName: checkout).rawValue == "library")
        #expect(PackageIdentity(checkoutName: upper).rawValue == "library.git")
    }

    @Test func resolvedIdentityPreservesMeaningfulSpellingAndCodableDoesNotEchoInput() throws {
        for text in ["Library.git", " Foo ", "CaféKit"] {
            let identity = try #require(PackageIdentity(resolvedIdentity: text))
            #expect(identity.rawValue == text.lowercased())
            #expect(try JSONDecoder().decode(PackageIdentity.self, from: JSONEncoder().encode(identity)) == identity)
        }
        #expect(PackageIdentity(resolvedIdentity: " Foo ") != PackageIdentity(resolvedIdentity: "Foo"))
        #expect(Set([PackageIdentity(resolvedIdentity: "LIBRARY"), PackageIdentity(resolvedIdentity: "library")]).count == 1)
        for text in ["", ".", "..", "private/value", "private\u{2028}value"] {
            #expect(PackageIdentity(resolvedIdentity: text) == nil)
            let data = try JSONEncoder().encode(["rawValue": text])
            do { _ = try JSONDecoder().decode(PackageIdentity.self, from: data); Issue.record("Expected invalid identity") }
            catch DecodingError.dataCorrupted(let context) { #expect(context.debugDescription == "Invalid package identity.") }
        }
    }
}
