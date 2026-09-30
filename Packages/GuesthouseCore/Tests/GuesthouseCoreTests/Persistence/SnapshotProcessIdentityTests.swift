import Foundation
import GuesthouseCore
import Testing

@Suite struct SnapshotProcessIdentityTests {
    let environment = DevelopmentEnvironment(id: EnvironmentID(uuid: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!), name: "Saved work")

    func identity(for id: EnvironmentID) -> ProcessIdentity {
        ProcessIdentity(pid: 123, startTime: Date(timeIntervalSince1970: 1_800_000_000.123456),
            executablePath: "/test/provider", argumentsDigest: "sha256:" + String(repeating: "a", count: 64),
            vmName: id.managedVMName, environmentID: id, recordedAt: Date(timeIntervalSince1970: 1_800_000_001.654321))
    }

    func snapshot() throws -> EnvironmentsSnapshot {
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        return EnvironmentsSnapshot(environments: [environment], slots: slots,
            provisioning: [environment.id: ProvisioningState(stage: .first, status: .awaitingInspection(EffectToken(UInt64.max)), issuedEffects: UInt64.max)],
            storageSelection: HostStorageSelection(volumeID: UUID()),
            processIdentities: [environment.id: identity(for: environment.id)])
    }

    @Test func roundTripKeepsExactIdentityAndUnknownOperation() throws {
        let original = try snapshot()
        let bytes = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: bytes)
        #expect(decoded == original)
        #expect(decoded.processIdentities[environment.id]?.startTime == original.processIdentities[environment.id]?.startTime)
        #expect(decoded.provisioning[environment.id]?.issuedEffects == UInt64.max)
        // Old writers must refuse instead of dropping process ownership evidence.
        #expect(throws: StateStoreError.newerSchemaVersion(found: EnvironmentsSnapshot.currentSchema, current: SchemaVersion(3)!)) {
            try SnapshotMigrator(current: SchemaVersion(3)!, migrations: []).migrate(bytes)
        }
    }

    @Test(arguments: [2, 3]) func migrationPreservesExistingEvidenceAndLeavesProcessUnknown(version: Int) throws {
        var expected = try snapshot()
        expected.processIdentities = [:]
        if version == 2 { expected.storageSelection = nil }
        // Keep the UInt64 token and Date numbers as typed encoder bytes, not JSONSerialization.
        let encoded = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let source = Data(encoded.replacingOccurrences(of: "\"schemaVersion\":4", with: "\"schemaVersion\":\(version)")
            .replacingOccurrences(of: "\"processIdentities\":{},", with: "")
            .replacingOccurrences(of: ",\"processIdentities\":{}", with: "").utf8)
        let migrated = try SnapshotMigrator.standard.migrate(source)
        #expect(migrated.from == SchemaVersion(version))
        let decoded = try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrated.data)
        #expect(decoded == expected)
        #expect(decoded.processIdentities.isEmpty) // No invented stopped/running state.
    }

    @Test(arguments: ["unknown", "mismatch", "pid", "digest", "vm", "path"])
    func invalidRecordsCannotBePublished(kind: String) throws {
        var value = try snapshot()
        var record = try #require(value.processIdentities[environment.id])
        var reason = StateStoreError.SnapshotInconsistency.processIdentity
        switch kind {
        case "unknown":
            let foreign = EnvironmentID()
            value.processIdentities[foreign] = identity(for: foreign)
            reason = .unknownProcessEnvironment
        case "mismatch": record.environmentID = EnvironmentID()
        case "pid": record.pid = 0
        case "digest": record.argumentsDigest = "raw arguments"
        case "vm": record.vmName = "another-vm"
        default: record.executablePath = "relative"
        }
        value.processIdentities[environment.id] = record
        #expect(throws: StateStoreError.inconsistentSnapshot(reason: reason)) { try value.validate() }
        #expect(throws: StateStoreError.inconsistentSnapshot(reason: reason)) { try JSONEncoder().encode(value) }
    }

    @Test(arguments: ["duplicate", "invalid", "mismatch", "missing"])
    func malformedIdentityObjectsAreRefused(kind: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        var records = try #require(object["processIdentities"] as? [String: Any])
        let key = environment.id.uuid.uuidString
        switch kind {
        case "duplicate": records[key.lowercased()] = records[key]
        case "invalid": records["invalid"] = records.removeValue(forKey: key)
        case "mismatch": records[UUID().uuidString] = records.removeValue(forKey: key)
        default: break
        }
        object["processIdentities"] = kind == "missing" ? nil : records
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func reusedPIDAcrossHistoricalRecordsIsNotCorruption() throws {
        var value = try snapshot()
        let second = DevelopmentEnvironment(name: "Other saved work")
        value.environments.append(second)
        try value.slots.reserve(second.id)
        var record = identity(for: second.id)
        record.startTime = record.startTime.addingTimeInterval(1)
        value.processIdentities[second.id] = record
        #expect(try JSONDecoder().decode(EnvironmentsSnapshot.self, from: JSONEncoder().encode(value)) == value)
    }
}
