import Foundation
import GuesthouseCore
import Testing

@Suite struct JournalRecordTests {
    let operationID = OperationID()
    let environmentID = EnvironmentID()
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    func record(_ outcome: JournalRecord.Outcome, operation: JournalOperation = .startEnvironment) -> JournalRecord {
        JournalRecord(id: operationID, environmentID: environmentID, operation: operation, timestamp: timestamp, outcome: outcome)
    }

    func object(_ record: JournalRecord) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }

    @Test(arguments: JournalOperation.allCases)
    func everyOperationRetainsItsInspectionDetail(operation: JournalOperation) throws {
        let original = record(.started, operation: operation)
        let restored = try JSONDecoder().decode(JournalRecord.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.operation == operation)
        #expect(restored.isSelfConsistent)
    }

    @Test func operationInventoryIncludesEveryStageAndCurrentRepair() {
        #expect(JournalOperation.allCases.count == 21)
        #expect(Set(JournalOperation.allCases).count == 21)
        #expect(JournalOperation.allCases.contains(.provision(stage: .sshPaired)))
        #expect(JournalOperation.allCases.contains(.repair(kind: .credentials)))
        #expect(JournalOperation.allCases.contains(.repair(kind: .download)))
    }

    @Test(arguments: [
        (JournalRecord.Outcome.started, true), (.checkpoint(.first), true),
        (.unknown, true), (.failed(.canceled), true),
        (.completed, false), (.notApplied, false), (.failed(.runtimeMissing), false),
    ])
    func recordOutcomesRetainTheirReplayMeaning(outcome: JournalRecord.Outcome, unresolved: Bool) throws {
        // The settled runtimeMissing fixture represents a verified failure, not an arbitrary
        // operationFailed callback. Unknown mutations must be journaled as unknown instead.
        let original = record(outcome, operation: .provision(stage: .first))
        let restored = try JSONDecoder().decode(JournalRecord.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.leavesInFlight == unresolved)
        #expect(restored.isSelfConsistent)
    }

    @Test func anExplicitlyUnknownFailureRetainsTheSameOperation() throws {
        let original = record(.failed(.operationOutcomeUnknown(operationID)))
        let restored = try JSONDecoder().decode(JournalRecord.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.leavesInFlight)
        #expect(restored.isSelfConsistent)
        #expect(!record(.notApplied).leavesInFlight)
    }

    @Test func unknownFailureIdentityMustAgreeWithTheRecord() {
        #expect(record(.failed(.operationOutcomeUnknown(operationID))).isSelfConsistent)
        #expect(!record(.failed(.operationOutcomeUnknown(OperationID()))).isSelfConsistent)
    }

    @Test func environmentErrorsMustNameTheRecordedEnvironment() {
        #expect(record(.failed(.guestNotReachable(environmentID))).isSelfConsistent)
        #expect(record(.failed(.hostKeyChanged(environmentID))).isSelfConsistent)
        #expect(!record(.failed(.guestNotReachable(EnvironmentID()))).isSelfConsistent)
        #expect(!record(.failed(.hostKeyChanged(EnvironmentID()))).isSelfConsistent)
    }

    @Test(arguments: ProvisioningStage.allCases)
    func checkpointsMustMatchTheProvisioningOperation(stage: ProvisioningStage) {
        #expect(record(.checkpoint(stage), operation: .provision(stage: stage)).isSelfConsistent)
        #expect(!record(.checkpoint(stage), operation: .importXcode).isSelfConsistent)
    }

    @Test func aCheckpointCannotClaimADifferentStage() {
        #expect(!record(.checkpoint(.ready), operation: .provision(stage: .first)).isSelfConsistent)
        #expect(!record(.checkpoint(.first), operation: .provision(stage: .ready)).isSelfConsistent)
    }

    @Test func structuredJournalFormatIsIndependentAndExplicit() throws {
        let original = record(.started)
        #expect(JournalRecord.currentFormat == 2)
        #expect(original.format == 2)
        #expect(try object(original)["format"] as? Int == 2)
        #expect(JournalRecord.canRead(2))
    }

    @Test(arguments: [-1, 0, 1, 3, 99, Int.max])
    func unsupportedFormatsIncludingTheLegacyPrototypeAreRefused(format: Int) throws {
        var fixture = try object(record(.started))
        fixture["format"] = format
        let data = try JSONSerialization.data(withJSONObject: fixture)
        #expect(!JournalRecord.canRead(format))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: data) }
    }

    @Test(arguments: ["true", "false", "\"2\"", "2.5", "null"])
    func aNonIntegerFormatCannotBeReinterpreted(format: String) throws {
        var fixture = try object(record(.started))
        fixture.removeValue(forKey: "format")
        let body = try #require(String(data: JSONSerialization.data(withJSONObject: fixture), encoding: .utf8))
        let data = Data(("{\"format\":" + format + "," + body.dropFirst()).utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: data) }
    }

    @Test func unversionedRecordsAreRefusedWithoutAnImplicitUpgrade() throws {
        var fixture = try object(record(.started))
        fixture.removeValue(forKey: "format")
        let data = try JSONSerialization.data(withJSONObject: fixture)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: data) }
    }

    @Test(arguments: ["operation", "outcome"])
    func unknownKindsAreRefused(field: String) throws {
        var fixture = try object(record(.started))
        fixture[field] = ["unsupported": [:]] as [String: [String: String]]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: data) }
    }

    @Test(arguments: ["id", "environmentID"])
    func malformedIdentitiesAreRefused(field: String) throws {
        var fixture = try object(record(.started))
        fixture[field] = "not-a-uuid"
        let data = try JSONSerialization.data(withJSONObject: fixture)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: data) }
    }

    @Test func unknownFieldsCannotBecomeJournalOrDiagnosticContent() throws {
        let original = record(.failed(.runtimeMissing))
        var fixture = try object(original)
        fixture["rawOutput"] = "test-only-discarded-response"
        fixture["metadata"] = ["authorization": "test-only-discarded-header"]
        let restored = try JSONDecoder().decode(JournalRecord.self, from: JSONSerialization.data(withJSONObject: fixture))
        #expect(restored == original)
        let encoded = try object(restored)
        #expect(Set(encoded.keys) == ["format", "id", "environmentID", "operation", "timestamp", "outcome"])
        #expect(encoded["rawOutput"] == nil)
        #expect(encoded["metadata"] == nil)
    }
}
