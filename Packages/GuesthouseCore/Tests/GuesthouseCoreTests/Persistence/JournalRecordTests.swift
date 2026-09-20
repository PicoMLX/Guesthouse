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

    func expectDecodingRefusal(_ record: JournalRecord) throws {
        #expect(!record.isSelfConsistent)
        let data = try JSONEncoder().encode(record)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(JournalRecord.self, from: data)
        }
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

    @Test func unknownFailureIdentityMustAgreeWithTheRecord() throws {
        #expect(record(.failed(.operationOutcomeUnknown(operationID))).isSelfConsistent)
        try expectDecodingRefusal(record(.failed(.operationOutcomeUnknown(OperationID()))))
    }

    @Test func environmentErrorsMustNameTheRecordedEnvironment() throws {
        for error in [GuesthouseError.guestNotReachable(environmentID), .hostKeyChanged(environmentID)] {
            let original = record(.failed(error))
            #expect(original.isSelfConsistent)
            let restored = try JSONDecoder().decode(JournalRecord.self, from: JSONEncoder().encode(original))
            #expect(restored == original)
        }
        try expectDecodingRefusal(record(.failed(.guestNotReachable(EnvironmentID()))))
        try expectDecodingRefusal(record(.failed(.hostKeyChanged(EnvironmentID()))))
    }

    @Test(arguments: ProvisioningStage.allCases)
    func checkpointsMustMatchTheProvisioningOperation(stage: ProvisioningStage) throws {
        let original = record(.checkpoint(stage), operation: .provision(stage: stage))
        #expect(original.isSelfConsistent)
        let restored = try JSONDecoder().decode(JournalRecord.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        try expectDecodingRefusal(record(.checkpoint(stage), operation: .importXcode))
    }

    @Test func aCheckpointCannotClaimADifferentStage() throws {
        try expectDecodingRefusal(record(.checkpoint(.ready), operation: .provision(stage: .first)))
        try expectDecodingRefusal(record(.checkpoint(.first), operation: .provision(stage: .ready)))
    }

    @Test func structuredJournalFormatIsIndependentAndExplicit() throws {
        let original = record(.started)
        #expect(JournalRecord.currentFormat == 2)
        #expect(original.format == 2)
        #expect(try object(original)["format"] as? Int == 2)
        #expect(JournalRecord.canRead(2))
    }

    @Test(arguments: ProvisioningStage.allCases)
    func recoveredCheckpointMetadataNeedsNoInventedOperation(stage: ProvisioningStage) throws {
        let checkpoint = Checkpoint(stage: stage, reachedAt: timestamp)
        let inspecting = try ProvisioningReducer.reduce(.initial, .inspectionRequested)
        let inspection = try #require(inspecting.state.status.pendingEffect)
        let recovered = try ProvisioningReducer.reduce(inspecting.state, .reconciled(inspection, .completed(checkpoint)))
        let write = try #require(recovered.state.status.pendingEffect)
        #expect(recovered.state.status == .persistingCheckpoint(checkpoint, operation: nil, write: write))
        #expect(recovered.effects == [.persistCheckpoint(checkpoint, write)])

        // Value/serialization contract only: the runtime store owns durable publication and
        // may acknowledge it only after its barriers succeed. No journal ID is fabricated.
        let data = try JSONEncoder().encode([environmentID: recovered.state])
        let metadata = try JSONDecoder().decode([EnvironmentID: ProvisioningState].self, from: data)
        let restored = try #require(metadata[environmentID])
        #expect(restored == recovered.state)
        let acknowledged = try ProvisioningReducer.reduce(restored, .checkpointPersisted(write, checkpoint))
        #expect(acknowledged.state.status == .completed(checkpoint))
        #expect(acknowledged.effects.isEmpty)
        let saved = try JSONEncoder().encode(acknowledged.state)
        #expect(try JSONDecoder().decode(ProvisioningState.self, from: saved) == acknowledged.state)
    }

    @Test(arguments: ["null", "missing"])
    func operationJournalStillRequiresARealIdentity(identity: String) throws {
        var fixture = try object(record(.checkpoint(.first), operation: .provision(stage: .first)))
        if identity == "null" { fixture["id"] = NSNull() }
        else { fixture.removeValue(forKey: "id") }
        let data = try JSONSerialization.data(withJSONObject: fixture)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: data) }
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
