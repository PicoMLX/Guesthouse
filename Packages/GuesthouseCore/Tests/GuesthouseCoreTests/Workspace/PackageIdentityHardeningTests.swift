import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct PackageIdentityHardeningTests {
    let sha = CommitSHA("0123456789abcdef0123456789abcdef01234567")!

    func resolved(identity: String, location: String) -> ResolvedPackagesFile {
        ResolvedPackagesFile(version: 3, pins: [.init(identity: PackageIdentity(resolvedIdentity: identity)!, kind: .remoteSourceControl, location: location, revision: sha.rawValue, version: "1.0.0", branch: nil)])
    }

    @Test func resolvedIdentitiesAreKeptVerbatim() throws {
        let file = try ResolvedPackagesFile.decode(Data(#"{"version":3,"pins":[{"identity":"mixed-repo.git","kind":"remoteSourceControl","location":"https://github.com/Org/Mixed-Repo.GIT","state":{"revision":"0123456789abcdef0123456789abcdef01234567","version":"1.0.0"}}]}"#.utf8))
        #expect(file.pins.first?.identity.rawValue == "mixed-repo.git")
        #expect(PackageIdentity(resolvedIdentity: "a/b") == nil)
        #expect(PackageIdentity(resolvedIdentity: "\u{202E}kit") == nil, "an override could make the name read as another package")
    }

    @Test func aBoundarySpaceBelongsToTheIdentityThatCarriesIt() throws {
        // SwiftPM takes a local dependency's identity from its checkout basename, so a
        // directory named ` SharedUI ` is the package `" sharedui "`. Folding it onto
        // `sharedui` would merge it with the app's real remote dependency and report a
        // collision that no re-resolve could clear, because the file is what SwiftPM writes.
        let json = #"""
        {"version":3,"pins":[
          {"identity":" sharedui ","kind":"localSourceControl","location":"/Users/dev/ SharedUI ","state":{"revision":"1111111111111111111111111111111111111111"}},
          {"identity":"sharedui","kind":"remoteSourceControl","location":"https://github.com/Org/SharedUI.git","state":{"revision":"0123456789abcdef0123456789abcdef01234567","version":"1.0.0"}}
        ]}
        """#
        let file = try ResolvedPackagesFile.decode(Data(json.utf8))
        #expect(file.pins.map(\.identity.rawValue) == [" sharedui ", "sharedui"])
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let package = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        #expect(LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [package.checkoutName: remote])
            == [.matched(identity: PackageIdentity(remote: remote), location: "https://github.com/Org/SharedUI.git")],
            "a neighbouring checkout whose name has boundary spaces is another package, not a collision")
    }

    @Test func aMirroredDependencyIsNotReportedAsAbsent() {
        // A dependency mirror makes SwiftPM record the mirror's identity while mapping the
        // location back to the original URL, so the app depends on the selected repository
        // under a name no checkout directory can carry (MVP-PLAN.md §6).
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let file = resolved(identity: "company-cache", location: "https://github.com/Org/SharedUI.git")
        let package = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        #expect(LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [package.checkoutName: remote])
            == [.identityMismatch(identity: PackageIdentity(remote: remote), pinned: PackageIdentity(resolvedIdentity: "company-cache")!, location: "https://github.com/Org/SharedUI.git")])
        // A repository the lockfile names nowhere is still reported as no dependency at all.
        let absent = WorkspaceRepository(role: .package, remote: RemoteURL("https://github.com/Org/Unrelated")!, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        #expect(LocalOverrideMatcher.match(selected: [absent], resolved: file, observedOrigins: [:])
            == [.notADependency(identity: PackageIdentity(location: "unrelated")!)])
    }

    @Test func aSourceControlPinWithoutARevisionIsRefused() throws {
        func pin(_ state: String) -> Data {
            Data(#"{"version":3,"pins":[{"identity":"sharedui","kind":"remoteSourceControl","location":"https://github.com/Org/SharedUI.git"\#(state)}]}"#.utf8)
        }
        // A pin that names no commit pins nothing: seeding the generated workspace from it
        // would resolve the dependency again instead of building the code the app ships.
        #expect(throws: ResolvedPackagesError.malformed("state")) { try ResolvedPackagesFile.decode(pin("")) }
        #expect(throws: ResolvedPackagesError.malformed("state")) { try ResolvedPackagesFile.decode(pin(#","state":"1.0.0""#)) }
        #expect(throws: ResolvedPackagesError.malformed("state.revision")) { try ResolvedPackagesFile.decode(pin(#","state":{"version":"1.0.0"}"#)) }
        // A revision that is present but blank identifies no commit either.
        #expect(throws: ResolvedPackagesError.malformed("state.revision")) { try ResolvedPackagesFile.decode(pin(#","state":{"revision":"","version":"1.0.0"}"#)) }
        #expect(throws: ResolvedPackagesError.malformed("state.revision")) { try ResolvedPackagesFile.decode(pin(#","state":{"revision":"  ","version":"1.0.0"}"#)) }
        #expect(throws: ResolvedPackagesError.malformed("state.version")) {
            try ResolvedPackagesFile.decode(pin(#","state":{"revision":"0123456789abcdef0123456789abcdef01234567","version":1}"#))
        }
        // A registry pin carries a version and no commit, and still decodes.
        let registry = try ResolvedPackagesFile.decode(Data(#"{"version":3,"pins":[{"identity":"registrykit","kind":"registry","location":"org.registrykit","state":{"version":"2.0.0"}}]}"#.utf8))
        #expect(registry.pins.first?.version == "2.0.0")
    }

    /// GitHub resolves `foo%2Dbar` to the same repository as `foo-bar`, but SwiftPM keeps the
    /// spelling and pins the identity `foo%2dbar`, which no checkout directory can carry.
    @Test func anEncodedPinLocationIsAnIdentityMismatchNotAnAbsentDependency() {
        let remote = RemoteURL("https://github.com/Org/foo-bar")!
        let file = resolved(identity: "foo%2dbar", location: "https://github.com/Org/foo%2Dbar.git")
        let package = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        #expect(LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [package.checkoutName: remote])
            == [.identityMismatch(identity: PackageIdentity(remote: remote), pinned: PackageIdentity(resolvedIdentity: "foo%2dbar")!, location: "https://github.com/Org/foo%2Dbar.git")],
            "the app depends on this repository, so it is never reported as one to add")
    }

    /// SwiftPM parses a pinned version with the semantic-version grammar and refuses the whole
    /// lockfile when it does not parse, so a wrapper seeded from it would fail at resolution.
    @Test func aPinnedVersionMustBeOneSwiftPMCanParse() throws {
        func pin(_ version: String) -> Data {
            Data(#"{"version":3,"pins":[{"identity":"sharedui","kind":"remoteSourceControl","location":"https://github.com/Org/SharedUI.git","state":{"revision":"0123456789abcdef0123456789abcdef01234567","version":"\#(version)"}}]}"#.utf8)
        }
        for bad in ["not-semver", "1.0", "1.0.0.0", "v1.0.0", "1.0.x"] {
            #expect(throws: ResolvedPackagesError.malformed("state.version")) { try ResolvedPackagesFile.decode(pin(bad)) }
        }
        for good in ["1.0.0", "0.1.0-beta.1", "1.2.3+build.5", "1.2.3-rc.1+exp.sha.5114f85", "1.0.0-", "1.0.0+", "1.0.0-beta..1"] {
            #expect(throws: Never.self) { try ResolvedPackagesFile.decode(pin(good)) }
        }
    }

    /// A registry pin is pinned by version alone, so SwiftPM refuses one that carries none.
    @Test func aRegistryPinWithoutAVersionIsRefused() {
        func pin(_ state: String) -> Data {
            Data(#"{"version":3,"pins":[{"identity":"registrykit","kind":"registry","location":"org.registrykit"\#(state)}]}"#.utf8)
        }
        #expect(throws: ResolvedPackagesError.malformed("state")) { try ResolvedPackagesFile.decode(pin("")) }
        #expect(throws: ResolvedPackagesError.malformed("state")) { try ResolvedPackagesFile.decode(pin(#","state":null"#)) }
        #expect(throws: ResolvedPackagesError.malformed("state.version")) { try ResolvedPackagesFile.decode(pin(#","state":{}"#)) }
        #expect(throws: ResolvedPackagesError.malformed("state.version")) { try ResolvedPackagesFile.decode(pin(#","state":{"branch":"main"}"#)) }
        #expect(throws: Never.self) { try ResolvedPackagesFile.decode(pin(#","state":{"version":"2.0.0"}"#)) }
    }

    /// A source-control pin's revision is the commit SwiftPM checked out, so text that is not
    /// a Git object ID pins nothing, however plausible it reads.
    @Test func aRevisionThatIsNotACommitIDIsRefused() throws {
        func pin(_ revision: String) -> Data {
            Data(#"{"version":3,"pins":[{"identity":"sharedui","kind":"remoteSourceControl","location":"https://github.com/Org/SharedUI.git","state":{"revision":"\#(revision)","version":"1.0.0"}}]}"#.utf8)
        }
        for bad in ["not-a-commit", "main", "0123456789abcdef", String(repeating: "0", count: 40), "0123456789abcdef0123456789abcdef0123456z"] {
            #expect(throws: ResolvedPackagesError.malformed("state.revision"), Comment(rawValue: bad)) { try ResolvedPackagesFile.decode(pin(bad)) }
        }
        let good = try ResolvedPackagesFile.decode(pin("0123456789ABCDEF0123456789abcdef01234567"))
        #expect(good.pins.first?.revision == "0123456789ABCDEF0123456789abcdef01234567", "the lockfile's own spelling is kept")
    }

    /// The lockfile is committed in a repository the user merely selected, so its size is
    /// bounded before the parser materializes it.
    @Test func anOversizedLockfileIsRefusedBeforeItIsParsed() {
        let padding = String(repeating: "p", count: ResolvedPackagesFile.maximumEncodedSize)
        let data = Data(#"{"version":3,"pins":[],"padding":"\#(padding)"}"#.utf8)
        #expect(throws: ResolvedPackagesError.tooLarge(bytes: data.count)) { try ResolvedPackagesFile.decode(data) }
        #expect(!ResolvedPackagesError.tooLarge(bytes: data.count).recoveryActions.isEmpty)
        #expect(throws: Never.self) { try ResolvedPackagesFile.decode(Data(#"{"version":3,"pins":[]}"#.utf8)) }
    }

    @Test func thePublicMatchingTypesAreSendable() {
        func requiringSendable<T: Sendable>(_ type: T.Type) {}
        requiringSendable(LocalOverrideMatcher.self)
        requiringSendable(LocalOverrideMatcher.MatchResult.self)
        requiringSendable(ResolvedPackagesFile.self)
        requiringSendable(PackageIdentity.self)
    }

    @Test func anIdentityFromALocationMatchesTheOneDerivedFromItsRemote() {
        // SwiftPM splits a location on the path separator alone, so the SCP form without a
        // path keeps its host prefix: `swift package resolve` on `git@github.com:Foo.git`
        // reports the identity `git@github.com:foo`.
        #expect(PackageIdentity(location: "git@example.com:SharedUI.git")?.rawValue == "git@example.com:sharedui")
        #expect(PackageIdentity(location: "git@github.com:PicoMLX/SharedUI.git")?.rawValue == "sharedui")
        // SwiftPM strips only a lowercase `.git`, so both routes to an identity keep `.GIT`
        // and a caller cannot derive two spellings for one dependency.
        let remote = RemoteURL("https://github.com/Org/Mixed-Repo.GIT")!
        #expect(PackageIdentity(location: "https://github.com/Org/Mixed-Repo.GIT") == PackageIdentity(remote: remote))
        #expect(PackageIdentity(location: "git@github.com:Org/Mixed-Repo.GIT")?.rawValue == "mixed-repo.git")
    }

    @Test func aLocationKeepsTheBoundarySpacesOfItsBasename() {
        // SwiftPM 6.3 writes `" foo "` for a local dependency at `/tmp/spmspace/ Foo `, so an
        // identity derived here without those spaces would never associate with that pin.
        #expect(PackageIdentity(location: "/tmp/spmspace/ Foo ")?.rawValue == " foo ")
        #expect(PackageIdentity(location: "/tmp/spmspace/ Foo ") == PackageIdentity(resolvedIdentity: " foo "))
        // A line terminator is framing from whatever read the location, never part of a name.
        #expect(PackageIdentity(location: "https://github.com/Org/SharedUI.git\n")?.rawValue == "sharedui")
    }

    @Test func aDecodedIdentityCarriesTheInvariantsADerivedOneHas() throws {
        let derived = PackageIdentity(remote: RemoteURL("https://github.com/Org/SharedUI")!)
        #expect(try JSONDecoder().decode(PackageIdentity.self, from: JSONEncoder().encode(derived)) == derived)
        // A hand-written spelling would otherwise hash and compare differently from the
        // identity derived for the same package, so a pin lookup would miss the dependency.
        #expect(try JSONDecoder().decode(PackageIdentity.self, from: Data(#"{"rawValue":"SharedUI"}"#.utf8)) == derived)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PackageIdentity.self, from: Data(#"{"rawValue":""}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PackageIdentity.self, from: Data(#"{"rawValue":"a/b"}"#.utf8)) }
    }

    @Test func anUnusualLocalIdentityDoesNotRejectTheWholeResolvedFile() throws {
        // SwiftPM derives a local dependency's identity from its checkout basename, so a
        // lockfile can carry `cafékit` or `space kit`; re-resolving writes the same file back,
        // so refusing it would leave the user the one advice that cannot work.
        let json = #"""
        {"version":3,"pins":[
          {"identity":"cafékit","kind":"localSourceControl","location":"/Users/dev/Café Kit","state":{"revision":"0123456789abcdef0123456789abcdef01234567"}},
          {"identity":"space kit","kind":"localSourceControl","location":"/Users/dev/Space Kit","state":{"revision":"0123456789abcdef0123456789abcdef01234567"}},
          {"identity":"sharedui","kind":"remoteSourceControl","location":"https://github.com/Org/SharedUI.git","state":{"revision":"0123456789abcdef0123456789abcdef01234567","version":"1.0.0"}}
        ]}
        """#
        let file = try ResolvedPackagesFile.decode(Data(json.utf8))
        #expect(file.pins.map(\.identity.rawValue) == ["cafékit", "space kit", "sharedui"])
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let package = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        #expect(LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [package.checkoutName: remote])
            == [.matched(identity: PackageIdentity(remote: remote), location: "https://github.com/Org/SharedUI.git")],
            "an unrelated local dependency no longer hides the selected package")
    }

    @Test func checkoutNamesAndOriginsMustCarryTheIdentity() {
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let renamed = WorkspaceRepository(role: .package, remote: remote, checkoutName: DirectoryName("UI"), baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let file = resolved(identity: "sharedui", location: "https://github.com/Org/SharedUI.git")
        #expect(LocalOverrideMatcher.match(selected: [renamed], resolved: file, observedOrigins: [renamed.checkoutName: remote]) == [.checkoutNameMismatch(identity: PackageIdentity(remote: remote), checkout: "UI")])
        let proper = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let elsewhere = RemoteURL("https://github.com/Fork/SharedUI")!
        #expect(LocalOverrideMatcher.match(selected: [proper], resolved: file, observedOrigins: [proper.checkoutName: elsewhere]) == [.originMismatch(identity: PackageIdentity(remote: remote), expected: remote.canonical, observed: elsewhere.canonical)])
        #expect(LocalOverrideMatcher.match(selected: [proper], resolved: file, observedOrigins: [proper.checkoutName: remote]) == [.matched(identity: PackageIdentity(remote: remote), location: "https://github.com/Org/SharedUI.git")])
    }

    @Test func aMixedCaseGitSuffixKeepsSwiftPMsSpelling() {
        // SwiftPM strips only a lowercase `.git`, so `Mixed-Repo.GIT` is the package
        // `mixed-repo.git`, which is what it writes into `Package.resolved`.
        let remote = RemoteURL("https://github.com/Org/Mixed-Repo.GIT")!
        #expect(remote.name == "Mixed-Repo.GIT")
        #expect(PackageIdentity(remote: remote).rawValue == "mixed-repo.git")
        #expect(RemoteURL(remote.canonical) == remote, "the canonical form still parses back to the same repository")
        let package = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let file = resolved(identity: "mixed-repo.git", location: remote.canonical)
        #expect(LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [package.checkoutName: remote]) == [.matched(identity: PackageIdentity(remote: remote), location: remote.canonical)])
    }

    @Test func anUnreadCheckoutIsNeverApproved() {
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let package = WorkspaceRepository(role: .package, remote: remote, baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let file = resolved(identity: "sharedui", location: "https://github.com/Org/SharedUI.git")
        #expect(LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [:]) == [.originUnknown(identity: PackageIdentity(remote: remote), checkout: package.checkoutName.rawValue)])
    }

    @Test func aCheckoutIdentityIsDerivedTheWaySwiftPMDerivesIt() {
        // SwiftPM strips a terminal `.git` from the directory name, so `repos/foo.git` is the
        // package `foo` and cannot replace a dependency whose identity is `foo.git`.
        #expect(PackageIdentity(checkoutName: DirectoryName("foo.git")!).rawValue == "foo")
        #expect(PackageIdentity(checkoutName: DirectoryName("SharedUI")!).rawValue == "sharedui")
        // A repository whose own name ends in `.git` has no round-trippable canonical form
        // and is refused before it can reach a checkout at all.
        #expect(RemoteURL("https://github.com/Org/foo.git.git") == nil)
        // A checkout named for another package is refused whatever its spelling.
        let remote = RemoteURL("https://github.com/Org/SharedUI")!
        let file = resolved(identity: "sharedui", location: "https://github.com/Org/SharedUI.git")
        let package = WorkspaceRepository(role: .package, remote: remote, checkoutName: DirectoryName("ModelKit.git"), baseBranch: BranchName("main")!, baseSHA: sha, taskBranch: BranchName("t")!)
        let results = LocalOverrideMatcher.match(selected: [package], resolved: file, observedOrigins: [package.checkoutName: remote])
        #expect(results == [.checkoutNameMismatch(identity: PackageIdentity(remote: remote), checkout: "ModelKit.git")])
    }

    @Test func resolvedFileErrorsAreActionable() {
        for error in [ResolvedPackagesError.notJSON, .missingVersion, .unsupportedVersion(9), .unknownKind("x"), .malformed("pins")] {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
            #expect(error.errorDescription == error.userMessage)
        }
    }
}
