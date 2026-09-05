import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeContractHardeningTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "Containment-\(UUID().uuidString)")

    @Test func danglingLinksAndEscapesAreRefusedWhileInsideLinksResolve() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "dangling"), withDestinationURL: URL(fileURLWithPath: "/nonexistent/outside/new-file"))
        #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: root.appending(path: "dangling"), within: root) }
        #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: root.appending(path: "dangling/child"), within: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "real"))
        #expect(throws: Never.self) { try RequestValidator.validateContainment(of: root.appending(path: "link/file"), within: root) }
        #expect(throws: Never.self) { try RequestValidator.validateContainment(of: root.appending(path: "real/new-file"), within: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: root.appending(path: "escape/file"), within: root) }
    }

    @Test func aRootReachedThroughAnAliasStillRefusesDanglingLinks() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let alias = FileManager.default.temporaryDirectory.appending(path: "Alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "dangling"), withDestinationURL: URL(fileURLWithPath: "/nonexistent/outside/new-file"))
        #expect(throws: RequestValidationError.pathEscapesRoot) {
            try RequestValidator.validateContainment(of: alias.appending(path: "dangling"), within: alias)
        }
    }

    @Test func observationsThatBoundToTheSameTextKeepTheirIdentity() {
        let long = String(repeating: "a", count: 400)
        let other = String(repeating: "a", count: 401)
        let first = ObservedTuple(codexCLIPath: long).sanitizedForWire()
        let second = ObservedTuple(codexCLIPath: other).sanitizedForWire()
        #expect(first.codexCLIPath != second.codexCLIPath, "two different observations never collapse into one verified value")
        #expect(first.codexCLIPath?.hasPrefix(String(repeating: "a", count: 100)) == true)
        #expect((first.codexCLIPath?.unicodeScalars.count ?? 0) <= 256, "the identity suffix counts against the same bound")
        let short = ObservedTuple(codexCLIPath: "/usr/local/bin/codex").sanitizedForWire()
        #expect(short.codexCLIPath == "/usr/local/bin/codex", "a value the sanitizer leaves alone is unchanged")
    }

    @Test func theTartVersionIsSanitizedOnTheWire() throws {
        let info = RuntimeVersionInfo(serviceVersion: "1.0", serviceBuild: "1", tart: .init(version: "2.36.0\u{1B}[31m evil", verified: true))
        #expect(info.tart?.version.contains("\u{1B}") == false)
        let json = #"{"serviceVersion":"1.0","serviceBuild":"1","protocolVersion":1,"tart":{"version":"2.36.0\u001b[31m","verified":true}}"#
        let decoded = try JSONDecoder().decode(RuntimeVersionInfo.self, from: Data(json.utf8))
        #expect(decoded.tart?.version.contains("\u{1B}") == false)
    }

    @Test func aPhaseFractionIsAlwaysEncodable() throws {
        let phase = ProgressPhase(kind: .copying, fraction: 0.5)
        #expect(phase.measured(.nan).fraction == nil)
        #expect(phase.measured(2).fraction == nil)
        #expect(phase.measured(0.25).fraction == 0.25)
        #expect(throws: Never.self) { try JSONEncoder().encode(phase.measured(.infinity)) }
    }

    @Test func aDanglingRootIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dangling = base.appending(path: "import")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: URL(fileURLWithPath: "/nonexistent/outside/new-file"))
        #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: dangling, within: dangling) }
        #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: dangling.appending(path: "x"), within: dangling) }
    }

    @Test func aDanglingAncestorOfTheRootIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Ancestor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appending(path: "link"), withDestinationURL: URL(fileURLWithPath: "/nonexistent/outside"))
        let root = base.appending(path: "link/subroot")
        #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: root, within: root) }
        #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: root.appending(path: "Xcode.app"), within: root) }
    }

    @Test func aForgedIdentityMarkerCannotImpersonateAnotherValue() {
        let long = String(repeating: "a", count: 400)
        let shortened = ObservedTuple(codexCLIPath: long).sanitizedForWire().codexCLIPath ?? ""
        // A CLI that reports the shortened text verbatim must not produce the same value.
        let forged = ObservedTuple(codexCLIPath: shortened).sanitizedForWire().codexCLIPath
        #expect(forged != shortened, "the shortened text of one observation is not the identity of another")
        // A short value that carries the marker literally keeps it neutralized and unchanged
        // otherwise, so it can never be read as an identity this type produced.
        let literal = ObservedTuple(codexCLIPath: "/opt/tool [exact:0123456789ab]").sanitizedForWire().codexCLIPath
        #expect(literal == "/opt/tool [exact\u{FFFD}:0123456789ab]")
    }

    @Test func capabilityDigestsDistinguishSeparatorPlacement() {
        let base = (0..<63).map { "cap\($0)" }
        let first = ObservedTuple(codexCLICapabilities: base + ["a", "b\u{0}c"]).sanitizedForWire().codexCLICapabilities
        let second = ObservedTuple(codexCLICapabilities: base + ["a\u{0}b", "c"]).sanitizedForWire().codexCLICapabilities
        #expect(first != second, "the digest is over a length-prefixed encoding, so the separator cannot move")
    }

    @Test func aDisplayNameIsBoundedByScalarsNotCharacters() {
        let oneCharacter = "👩" + String(repeating: "\u{1F3FB}", count: 5_000)
        #expect(oneCharacter.count == 1)
        #expect(throws: RequestValidationError.invalidDisplayName) {
            try RequestValidator.validate(FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: oneCharacter))
        }
    }

    @Test func aCappedCapabilityListKeepsItsIdentity() {
        let many = (0..<200).map { "cap\($0)" }
        var other = many; other[199] = "different"
        let first = ObservedTuple(codexCLICapabilities: many).sanitizedForWire().codexCLICapabilities
        let second = ObservedTuple(codexCLICapabilities: other).sanitizedForWire().codexCLICapabilities
        #expect(first?.count == 64)
        #expect(first != second, "two lists that share their first entries keep different identities")
        #expect(first?.contains { $0.contains("137 more") } == true)
        let few = ObservedTuple(codexCLICapabilities: ["a", "b"]).sanitizedForWire().codexCLICapabilities
        #expect(few == ["a", "b"], "a list under the cap is untouched")
    }

    @Test func aForgedRedactionMarkerDoesNotSuppressTheIdentity() {
        let a = "/opt/[redacted:token]/" + String(repeating: "a", count: 400)
        let b = "/opt/[redacted:token]/" + String(repeating: "a", count: 401)
        let first = ObservedTuple(codexCLIPath: a).sanitizedForWire().codexCLIPath
        let second = ObservedTuple(codexCLIPath: b).sanitizedForWire().codexCLIPath
        #expect(first != second, "marker text in the value is not evidence that a secret was removed")
        #expect(first?.contains("[exact:") == true)
    }

    @Test func lineSeparatorsAreNotDisplayNames() {
        for bad in ["Xcode\u{2028}.app", "Xcode\u{2029}.app", "Xcode\u{202E}.app"] {
            #expect(throws: RequestValidationError.invalidDisplayName) {
                try RequestValidator.validate(FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: bad))
            }
        }
    }

    @Test func theVersionHeaderIsCheckedBeforeThePayload() throws {
        let foreign = #"{"protocolVersion":99,"request":{"somethingNewer":{}}}"#
        let error = #expect(throws: RuntimeRequestEnvelope.ProtocolMismatch.self) { try JSONDecoder().decode(RuntimeRequestEnvelope.self, from: Data(foreign.utf8)) }
        #expect(error?.client == RuntimeProtocolVersion(99))
        #expect(error?.error == .protocolMismatch(client: 99, service: RuntimeProtocolVersion.current.rawValue))
        let current = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .runtimeVersion))
        #expect(try JSONDecoder().decode(RuntimeRequestEnvelope.self, from: current).request == .runtimeVersion)
    }

    @Test func progressFractionsOutsideTheContractAreDropped() throws {
        #expect(ProgressPhase(kind: .copying, fraction: .nan).fraction == nil)
        #expect(ProgressPhase(kind: .copying, fraction: .infinity).fraction == nil)
        #expect(ProgressPhase(kind: .copying, fraction: 1.5).fraction == nil)
        #expect(ProgressPhase(kind: .copying, fraction: -0.1).fraction == nil)
        #expect(ProgressPhase(kind: .copying, fraction: 0.5).fraction == 0.5)
        let decoded = try JSONDecoder().decode(ProgressPhase.self, from: Data(#"{"kind":"copying","fraction":7,"cancelable":true}"#.utf8))
        #expect(decoded.fraction == nil)
        _ = try JSONEncoder().encode(RuntimeEvent.progress(OperationID(), ProgressPhase(kind: .copying, fraction: .nan)))
    }

    @Test func neutralizingAnIdentityMarkerIsInjective() {
        let plain = ObservedTuple(codexCLIPath: "/opt/tool [exact:0123456789ab]").sanitizedForWire().codexCLIPath
        let alreadyEscaped = ObservedTuple(codexCLIPath: "/opt/tool [exact\u{FFFD}:0123456789ab]").sanitizedForWire().codexCLIPath
        #expect(plain != alreadyEscaped, "neutralizing a marker never maps two reported values onto one identity")
    }

    @Test func aLiteralCapabilityCannotImpersonateACappedList() {
        let capped = ObservedTuple(codexCLICapabilities: (0..<200).map { "cap\($0)" }).sanitizedForWire().codexCLICapabilities ?? []
        // A probe reporting the capped list verbatim stays under the cap, so its entries are
        // taken literally; the omitted-count entry must not survive that as an identity.
        let forged = ObservedTuple(codexCLICapabilities: capped).sanitizedForWire().codexCLICapabilities ?? []
        #expect(Set(forged) != Set(capped), "a literal capability cannot pass a different set off as a capped one")
    }

    /// The sanitizer reads the bound plus its lookahead and nothing more. A value longer than
    /// that has a tail nothing inspected: it is neither redacted nor covered by a digest, so two
    /// such values used to bound to one identical value that still counted as an exact
    /// observation, and a replaced executable could match the record of the one before it.
    @Test func anObservationLongerThanTheInspectedWindowIsUnknown() {
        let unseen = String(repeating: "a", count: 800)
        let first = ObservedTuple(codexCLIPath: unseen + "device-code-one").sanitizedForWire()
        let second = ObservedTuple(codexCLIPath: unseen + "device-code-two").sanitizedForWire()
        #expect(first.codexCLIPath == nil)
        #expect(second.codexCLIPath == nil)
        #expect(first.unknownFields.contains(.codexCLIPath))
        // Everything the sanitizer does read keeps its identity; the window is the bound plus
        // the lookahead, and the first scalar past it is what makes the value unknown.
        let window = 256 + GuesthouseError.sanitizeLookahead
        #expect(ObservedTuple(codexCLIPath: String(repeating: "a", count: window)).sanitizedForWire().codexCLIPath?.contains("[exact:") == true)
        #expect(ObservedTuple(codexCLIPath: String(repeating: "a", count: window + 1)).sanitizedForWire().codexCLIPath == nil)
        // Nothing past the window is escaped or copied on the way to that answer: the marker
        // neutralization now runs on the window, not on arbitrarily long CLI output.
        #expect(ObservedTuple(codexCLIPath: String(repeating: "/opt [exact:0123456789ab] ", count: 100_000)).sanitizedForWire().codexCLIPath == nil)
        // Escaping doubles every escape scalar, so a value inside the window when it was
        // measured can leave it before the sanitizer reads it. The tail is then neither
        // redacted nor visible, and the digest would still cover the credential in it.
        let token = " ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let grown = String(repeating: "\u{FFFD}", count: window - token.unicodeScalars.count) + token
        #expect(grown.unicodeScalars.count == window)
        #expect(ObservedTuple(codexCLIPath: grown).sanitizedForWire().codexCLIPath == nil)
    }

    /// Two paths that differ only in a credential redact to the same text. Reporting that text
    /// as an exact observation reused one executable's connection-verification record for
    /// another (MVP-PLAN.md §5), so a value a secret was removed from is unknown instead.
    @Test func anObservationASecretWasRemovedFromIsNotAnIdentity() {
        let first = ObservedTuple(codexCLIPath: "/opt/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab/codex").sanitizedForWire()
        let second = ObservedTuple(codexCLIPath: "/opt/ghp_ZYXWVUTSRQPONMLKJIHGFEDCBA9876543210ba/codex").sanitizedForWire()
        #expect(first.codexCLIPath == nil)
        #expect(second.codexCLIPath == nil)
        #expect(first.unknownFields.contains(.codexCLIPath))
        // A fully known observation stops being exact when one of its values is redacted, so
        // nothing can be verified against a record that named a different executable.
        var complete = ObservedTuple(Self.knownTuple)
        #expect(complete.sanitizedForWire().exact != nil)
        complete.codexCLIPath = "/opt/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab/codex"
        #expect(complete.sanitizedForWire().exact == nil)
    }

    /// A credential split by a parameterless escape sequence is removed before the redactor
    /// runs, so the sanitizer used to report the result as merely normalized and an identity
    /// digest of the original credential was published alongside it.
    @Test func aCredentialSplicedByAnEscapeCountsAsRedaction() {
        let spliced = "ghp_ABCDEFGHIJ\u{1B}[KLMNOPQRSTUVWXYZ0123456789ab"
        let (text, redacted) = GuesthouseError.sanitizeReporting(spliced, limit: 256)
        #expect(text.contains("[redacted:spliced-escape]"))
        #expect(redacted, "dropping the spliced run removes a credential; that is redaction, not normalization")
        let observed = ObservedTuple(codexCLIPath: "/opt/" + spliced).sanitizedForWire()
        #expect(observed.codexCLIPath == nil, "no digest of the removed credential, and no identity either")
    }

    /// Every entry is redacted and bounded and the canonical list is built before the 64-entry
    /// cap applies, so the raw count is what has to be bounded first: otherwise a guest that
    /// answers a capability probe with its whole output decides how much work a status costs.
    @Test func aCapabilityListLongerThanAProbeCouldReportIsUnknown() {
        var reported = ObservedTuple()
        reported.codexCLICapabilities = (0...ObservedTuple.maximumReportedCapabilities).map { "cap\($0)" }
        #expect(reported.sanitizedForWire().codexCLICapabilities == nil, "reported unknown rather than inspected in full")
        var atTheBound = ObservedTuple()
        atTheBound.codexCLICapabilities = (0..<ObservedTuple.maximumReportedCapabilities).map { "cap\($0)" }
        #expect(atTheBound.sanitizedForWire().codexCLICapabilities?.count == ObservedTuple.maximumCapabilities)
    }

    /// A probe may report the same capabilities in any order, or twice. Which entries the cap
    /// keeps and what the digest covers must not depend on that, or one capability set would
    /// produce two identities and revalidate a connection that never changed.
    @Test func aCappedCapabilityListDoesNotDependOnTheOrderItWasReported() {
        let many = (0..<200).map { "cap\($0)" }
        // Assigned rather than passed to the initializer, which normalizes on the way in.
        var reported = ObservedTuple()
        reported.codexCLICapabilities = many
        var shuffled = ObservedTuple()
        shuffled.codexCLICapabilities = many.reversed() + ["cap7", "cap7"]
        let canonical = reported.sanitizedForWire().codexCLICapabilities
        #expect(canonical?.count == 64)
        #expect(canonical == shuffled.sanitizedForWire().codexCLICapabilities, "one capability set has one identity, however it is ordered or repeated")
        var changed = ObservedTuple()
        changed.codexCLICapabilities = Array(many.dropLast()) + ["different"]
        #expect(changed.sanitizedForWire().codexCLICapabilities != canonical, "a set that really differs still does")
    }

    static let knownTuple = CompatibilityTuple(
        hostMacOSVersion: SemanticVersion([26, 4]),
        hostMacOSBuild: "25E200",
        codexDesktopVersion: "1.2.0",
        codexDesktopBuild: "120",
        codexDesktopPath: "/Applications/Codex.app",
        runtimeProtocolVersion: 1,
        tartVersion: "2.36.0",
        guestMacOSBuild: "25E200",
        xcodeBuild: "17A100",
        codexCLIVersion: "0.50.0",
        codexCLIPath: "/usr/local/bin/codex",
        codexCLIInstallations: 1,
        codexCLICapabilities: ["apply-patch"],
        githubCLIVersion: "2.60.0",
        provisioningScriptVersion: "1.0.0"
    )

    @Test func aSanitizedStatusSurvivesTheWireUnchanged() throws {
        let observed = ObservedTuple(
            codexDesktopPath: String(repeating: "a", count: 400),
            codexCLICapabilities: (0..<200).map { "cap\($0)" }
        )
        let status = EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped, readiness: .ready, observed: observed)
        #expect(status.observed.codexDesktopPath?.contains("[exact:") == true)
        let decoded = try JSONDecoder().decode(EnvironmentStatus.self, from: JSONEncoder().encode(status))
        #expect(decoded == status, "the receiver evaluates the identity the sender computed, not a re-escaped one")
    }

    @Test func credentialShapedDisplayNamesAreRefused() {
        // The bundle name ends where the extension begins, which is no word boundary at all.
        for bad in ["ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab.app", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"] {
            #expect(throws: RequestValidationError.invalidDisplayName, "\(bad)") {
                try RequestValidator.validate(FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: bad))
            }
        }
        // A decomposed name is ordinary on this filesystem; only a credential is refused.
        for good in ["Xcode.app", "Cafe\u{301}.app"] {
            #expect(throws: Never.self, "\(good)") {
                try RequestValidator.validate(FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: good))
            }
        }
    }

    @Test func anUncertainReasonIsBoundedAndRedacted() throws {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let state = EnvironmentStatus.VMState.uncertain(reason: SanitizedText("pid 42 \u{1B}[31mheld \(token)"))
        guard case .uncertain(let reason) = state else { Issue.record("not uncertain"); return }
        #expect(!reason.value.contains(token))
        #expect(!reason.value.contains("\u{1B}"))
        let decoded = try JSONDecoder().decode(EnvironmentStatus.VMState.self, from: Data(#"{"uncertain":{"reason":"\#(token)"}}"#.utf8))
        #expect(decoded == .uncertain(reason: "[redacted:github-token]"))
    }

    @Test func observedValuesAreBoundedAndRedactedOnTheWire() throws {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let observed = ObservedTuple(codexCLIVersion: "0.50.0 \(token)", codexCLIPath: String(repeating: "x", count: 5_000), codexCLICapabilities: (0..<200).map { "cap\($0)\u{1B}[31m" })
        let status = EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped, readiness: .ready, observed: observed)
        // A value the redactor emptied of a secret, and one longer than the sanitizer reads,
        // are both unknown: neither can serve as the identity the tuple is compared by.
        #expect(status.observed.codexCLIVersion == nil)
        #expect(status.observed.codexCLIPath == nil)
        #expect(status.observed.unknownFields.contains(.codexCLIVersion))
        #expect(status.observed.unknownFields.contains(.codexCLIPath))
        // A value the sanitizer merely normalized keeps its place, and its identity.
        #expect(ObservedTuple(codexCLIVersion: "0.50.0\u{1B}[31m").sanitizedForWire().codexCLIVersion?.hasPrefix("0.50.0 [exact:") == true)
        #expect(status.observed.codexCLICapabilities?.count == 64)
        #expect(status.observed.codexCLICapabilities?.allSatisfy { !$0.contains("\u{1B}") } == true)
        let decoded = try JSONDecoder().decode(ObservedTuple.self, from: Data(#"{"tartVersion":"\#(token)"}"#.utf8))
        #expect(decoded.tartVersion == "[redacted:github-token]")
    }
}
