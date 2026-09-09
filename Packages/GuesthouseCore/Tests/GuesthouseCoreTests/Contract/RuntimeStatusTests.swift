import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeStatusTests {
    static func status(_ observed: ObservedTuple = ObservedTuple(CompatibilityTupleTests.tuple())) -> EnvironmentStatus {
        EnvironmentStatus(environmentID: EnvironmentID(), vm: .stopped, readiness: .checking, observed: observed)
    }

    /// Deliberately bypass the sender's admission to exercise an untrusted wire payload.
    static func decodeStatus(_ observed: ObservedTuple) throws -> EnvironmentStatus {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status())) as? [String: Any])
        object["observed"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed))
        return try JSONDecoder().decode(EnvironmentStatus.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test(arguments: [EnvironmentStatus.VMState.notFound, .stopped, .running,
                      .uncertain(reason: .ownershipUnproven), .uncertain(reason: .processIdentityChanged),
                      .uncertain(reason: .inspectionFailed), .uncertain(reason: .operationOutcomeUnknown)],
          [EnvironmentStatus.Readiness.checking, .ready, .needsAttention(.runtimeMissing)])
    func statusRoundTripsPreserveCorrelatedState(vm: EnvironmentStatus.VMState, readiness: EnvironmentStatus.Readiness) throws {
        let value = EnvironmentStatus(environmentID: EnvironmentID(), vm: vm, readiness: readiness,
                                      inFlightOperation: OperationID(), observed: ObservedTuple(CompatibilityTupleTests.tuple()),
                                      reconciledAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try JSONDecoder().decode(EnvironmentStatus.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test(arguments: VMProvider.allCases)
    func exactPrivateIdentitySurvivesBothSides(provider: VMProvider) throws {
        var tuple = CompatibilityTupleTests.tuple(provider: provider)
        tuple.codexDesktopPath = "/Applications/Cafe\u{301} Private/Codex.app"
        tuple.codexCLIPath = "/Users/developer/private [exact:literal]/codex"
        tuple.provisioningScriptVersion = "abcdef123"
        let observed = ObservedTuple(tuple)
        #expect(Self.status(observed).observed == observed)
        #expect(try Self.decodeStatus(observed).observed == observed)
        #expect(try Self.decodeStatus(observed).observed.exact == tuple)
    }

    @Test(arguments: [CompatibilityField.hostMacOSBuild, .codexDesktopVersion, .codexDesktopBuild,
                      .codexDesktopPath, .runtimeVersion, .guestMacOSBuild, .xcodeBuild,
                      .codexCLIVersion, .codexCLIPath, .githubCLIVersion, .provisioningScriptVersion])
    func everyMalformedStringBecomesUnknownWithoutChangingOtherIdentity(field: CompatibilityField) throws {
        let tuple = CompatibilityTupleTests.tuple()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tuple)) as? [String: Any])
        object[field.rawValue] = "private marker"
        let observed = try JSONDecoder().decode(ObservedTuple.self, from: JSONSerialization.data(withJSONObject: object))
        let local = Self.status(observed)
        let remote = try Self.decodeStatus(observed)
        #expect(local.observed == remote.observed)
        #expect(remote.observed.unknownFields == [field])
        #expect(remote.observed.exact == nil)
        #expect(!String(decoding: try JSONEncoder().encode(remote), as: UTF8.self).contains("private marker"))
        #expect(try CompatibilityEvaluatorTests.evaluate(remote.observed, history: [CompatibilityEvaluatorTests.record()])
                == .needsValidation(.unknownFields([field])))
    }

    @Test(arguments: CompatibilityField.allCases)
    func unknownFieldsRemainUnknown(field: CompatibilityField) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(CompatibilityTupleTests.tuple())) as? [String: Any])
        object.removeValue(forKey: field.rawValue)
        let observed = try JSONDecoder().decode(ObservedTuple.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(Self.status(observed).observed.unknownFields == [field])
        #expect(try Self.decodeStatus(observed).observed.unknownFields == [field])
    }

    @Test func byteBoundsPreserveTheFullValueOrMakeItUnknown() throws {
        let version = "1" + String(repeating: "a", count: 255)
        let path = "/" + String(repeating: "p", count: 1023)
        var observed = ObservedTuple(codexCLIVersion: version, codexCLIPath: path, codexCLICapabilities: [version])
        #expect(try Self.decodeStatus(observed).observed == observed)
        observed.codexCLIVersion = version + "a"
        observed.codexCLIPath = path + "a"
        observed.codexCLICapabilities = [version + "a"]
        #expect(Self.status(observed).observed == ObservedTuple())
        #expect(try Self.decodeStatus(observed).observed == ObservedTuple())
    }

    @Test(arguments: ["/", "//", "/opt/../bin/codex", "/opt/./codex", "/opt/codex/", "/opt/\u{1B}[31mcodex", "/opt/\u{202E}codex"])
    func invalidPathsAreNeverNormalizedIntoEvidence(path: String) throws {
        let observed = ObservedTuple(codexDesktopPath: path, codexCLIPath: path)
        #expect(Self.status(observed).observed == ObservedTuple())
        #expect(try Self.decodeStatus(observed).observed == ObservedTuple())
    }

    @Test func distinctPrivatePathsStayDistinctWhileInvalidPathsCannotVerify() throws {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexCLIPath = "/opt/private-one/codex"
        let history = [try CompatibilityEvaluatorTests.record(tuple)]
        var other = ObservedTuple(tuple)
        other.codexCLIPath = "/opt/private-two/codex"
        #expect(try CompatibilityEvaluatorTests.evaluate(Self.decodeStatus(other).observed, history: history)
                == .needsValidation(.changedSinceLastVerified([.codexCLIPath])))
        other.codexCLIPath = "/opt/private-one/./codex"
        #expect(try CompatibilityEvaluatorTests.evaluate(Self.decodeStatus(other).observed, history: history)
                == .needsValidation(.unknownFields([.codexCLIPath])))
    }

    @Test(arguments: [(0, CompatibilityState.NeedsValidationReason.codexCLIMissing),
                      (2, .competingInstallations(count: 2))])
    func adverseInstallationCountsRemainActionable(count: Int, reason: CompatibilityState.NeedsValidationReason) throws {
        let observed = ObservedTuple(codexCLIInstallations: count)
        #expect(try Self.decodeStatus(observed).observed.codexCLIInstallations == count)
        #expect(try CompatibilityEvaluatorTests.evaluate(Self.decodeStatus(observed).observed) == .needsValidation(reason))
    }

    @Test func invalidNumericObservationsBecomeUnknown() throws {
        let observed = ObservedTuple(runtimeProtocolVersion: 0, codexCLIInstallations: -1)
        #expect(Self.status(observed).observed == ObservedTuple())
        #expect(try Self.decodeStatus(observed).observed == ObservedTuple())
        #expect(try Self.decodeStatus(ObservedTuple(runtimeProtocolVersion: 8, codexCLIInstallations: 1)).observed
                == ObservedTuple(runtimeProtocolVersion: 8, codexCLIInstallations: 1))
    }

    @Test func capabilityAdmissionDoesNotTruncateOrRewriteIdentity() throws {
        let names = (0..<64).map { "cap\($0)" }
        let observed = ObservedTuple(codexCLICapabilities: names.reversed())
        #expect(try Self.decodeStatus(observed).observed == ObservedTuple(codexCLICapabilities: names))
        let oversized = ObservedTuple(codexCLICapabilities: Array(repeating: "same", count: 65))
        #expect(Self.status(oversized).observed.codexCLICapabilities == nil)
        #expect(throws: DecodingError.self) { try Self.decodeStatus(oversized) }
        #expect(try Self.decodeStatus(ObservedTuple(codexCLICapabilities: [])).observed.codexCLICapabilities == [])
    }

    @Test(arguments: ["", "has space", "cap\u{1B}[31m", "a/b", "ä"])
    func malformedCapabilitiesMakeTheEntireSetUnknown(value: String) throws {
        let observed = ObservedTuple(codexCLICapabilities: ["valid", value])
        #expect(Self.status(observed).observed.codexCLICapabilities == nil)
        #expect(try Self.decodeStatus(observed).observed.codexCLICapabilities == nil)
    }

    @Test(arguments: EnvironmentStatus.UncertaintyReason.allCases)
    func uncertaintyUsesClosedExplanationsAndInspection(reason: EnvironmentStatus.UncertaintyReason) throws {
        let state = EnvironmentStatus.VMState.uncertain(reason: reason)
        #expect(try JSONDecoder().decode(EnvironmentStatus.VMState.self, from: JSONEncoder().encode(state)) == state)
        #expect(!reason.userMessage.isEmpty)
        #expect(reason.recoveryActions == [.inspectState, .cancel])
    }

    @Test func rawUncertaintyTextIsNotAccepted() {
        let data = Data(#"{"uncertain":{"reason":"private process output"}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EnvironmentStatus.VMState.self, from: data) }
    }

    @Test(arguments: ProgressPhase.Kind.allCases, [0.0, 0.5, 1.0])
    func measuredProgressRoundTrips(kind: ProgressPhase.Kind, fraction: Double) throws {
        let value = ProgressPhase(kind: kind, fraction: fraction, cancelable: false)
        #expect(try JSONDecoder().decode(ProgressPhase.self, from: JSONEncoder().encode(value)) == value)
        #expect(value.measured(0.25) == ProgressPhase(kind: kind, fraction: 0.25, cancelable: false))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -0.1, 1.1])
    func invalidMeasurementsRemainEncodableAndIndeterminate(fraction: Double) throws {
        let phase = ProgressPhase(kind: .copying, fraction: fraction)
        #expect(phase.fraction == nil)
        #expect(phase.measured(fraction).fraction == nil)
        #expect(try JSONDecoder().decode(ProgressPhase.self, from: JSONEncoder().encode(phase)) == phase)
    }

    @Test func decodedProgressPreservesBoundsAndCancellationHint() throws {
        let value = try JSONDecoder().decode(ProgressPhase.self, from: Data(#"{"kind":"copying","fraction":7,"cancelable":false}"#.utf8))
        #expect(value.fraction == nil)
        #expect(!value.cancelable)
        let absent = try JSONDecoder().decode(ProgressPhase.self, from: Data(#"{"kind":"copying"}"#.utf8))
        #expect(absent.fraction == nil)
        #expect(absent.cancelable)
    }
}
