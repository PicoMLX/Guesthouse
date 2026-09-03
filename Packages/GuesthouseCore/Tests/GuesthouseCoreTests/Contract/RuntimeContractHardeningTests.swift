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
        #expect(first?.last?.contains("137 more") == true)
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

    @Test func observedValuesAreBoundedAndRedactedOnTheWire() throws {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let observed = ObservedTuple(codexCLIVersion: "0.50.0 \(token)", codexCLIPath: String(repeating: "x", count: 5_000), codexCLICapabilities: (0..<200).map { "cap\($0)\u{1B}[31m" })
        let status = EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped, readiness: .ready, observed: observed)
        #expect(status.observed.codexCLIVersion?.contains(token) == false)
        #expect(status.observed.codexCLIVersion?.contains("[redacted:github-token]") == true)
        #expect((status.observed.codexCLIPath?.unicodeScalars.count ?? 0) <= 257)
        #expect(status.observed.codexCLICapabilities?.count == 64)
        #expect(status.observed.codexCLICapabilities?.allSatisfy { !$0.contains("\u{1B}") } == true)
        let decoded = try JSONDecoder().decode(ObservedTuple.self, from: Data(#"{"tartVersion":"\#(token)"}"#.utf8))
        #expect(decoded.tartVersion == "[redacted:github-token]")
    }
}
