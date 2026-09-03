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
