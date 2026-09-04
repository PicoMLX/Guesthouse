import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct VMSlotInventoryTests {
    let a = EnvironmentID()
    let b = EnvironmentID()
    let c = EnvironmentID()

    @Test func thirdReservationFails() throws {
        var inventory = VMSlotInventory()
        try inventory.reserve(a)
        try inventory.reserve(b)
        #expect(inventory.isFull)
        #expect(throws: VMSlotError.inventoryFull(maximum: 2)) {
            try inventory.reserve(c)
        }
        #expect(inventory.state(of: c) == nil)
    }

    @Test func reserveIsIdempotentPerEnvironment() throws {
        var inventory = VMSlotInventory()
        try inventory.reserve(a)
        try inventory.reserve(a)
        #expect(inventory.occupiedSlots == 1)
        #expect(inventory.availableSlots == 1)
    }

    @Test func preservedEnvironmentStillOccupiesSlot() throws {
        var inventory = VMSlotInventory()
        try inventory.reserve(a)
        try inventory.reserve(b)
        try inventory.markPreserved(a)
        #expect(inventory.state(of: a) == .preserved)
        #expect(inventory.isFull)
        #expect(throws: VMSlotError.inventoryFull(maximum: 2)) {
            try inventory.reserve(c)
        }
    }

    @Test func releaseFreesSlotAndUnknownReleaseIsHarmless() throws {
        var inventory = VMSlotInventory()
        try inventory.reserve(a)
        try inventory.reserve(b)
        inventory.release(a)
        inventory.release(c)
        #expect(inventory.availableSlots == 1)
        try inventory.reserve(c)
        #expect(inventory.isFull)
    }

    @Test func preservedEnvironmentReturnsToActiveWithoutReleasingItsSlot() throws {
        var inventory = VMSlotInventory()
        try inventory.reserve(a)
        try inventory.markPreserved(a)
        try inventory.reserve(a)
        #expect(inventory.state(of: a) == .preserved, "reserve never changes an existing slot's state")
        try inventory.markActive(a)
        #expect(inventory.state(of: a) == .active)
        #expect(inventory.occupiedSlots == 1)
        #expect(throws: VMSlotError.unknownEnvironment(b)) { try inventory.markActive(b) }
    }

    @Test func markingUnknownEnvironmentPreservedFails() {
        var inventory = VMSlotInventory()
        #expect(throws: VMSlotError.unknownEnvironment(a)) {
            try inventory.markPreserved(a)
        }
    }

    @Test func errorsCarryUserFacingMessageAndRecovery() {
        let full = VMSlotError.inventoryFull(maximum: 2)
        #expect(full.errorDescription?.contains("at most 2") == true)
        #expect(full.recoverySuggestion?.isEmpty == false)
        let unknown = VMSlotError.unknownEnvironment(a)
        #expect(unknown.errorDescription?.contains(a.description) == true)
        #expect(unknown.recoverySuggestion?.isEmpty == false)
    }

    @Test func roundTripsThroughJSON() throws {
        var inventory = VMSlotInventory()
        try inventory.reserve(a)
        try inventory.reserve(b)
        try inventory.markPreserved(b)
        let data = try JSONEncoder().encode(inventory)
        let decoded = try JSONDecoder().decode(VMSlotInventory.self, from: data)
        #expect(decoded == inventory)
    }

    @Test func decodingMoreThanMaximumSlotsIsAnActionableError() throws {
        let slots = [a, b, c].map { VMSlotInventory.Slot(environmentID: $0) }
        let data = try JSONEncoder().encode(["slots": slots])
        let error = #expect(throws: VMSlotError.self) {
            try JSONDecoder().decode(VMSlotInventory.self, from: data)
        }
        #expect(error == .corruptInventory(reason: .tooManySlots(found: 3, maximum: VMSlotInventory.maximumSlots)))
        #expect(error?.userMessage.contains("3") == true)
        #expect(error?.recoveryMessage.isEmpty == false)
    }

    @Test func theInventoryCarriesItsFormatVersion() throws {
        let data = try JSONEncoder().encode(VMSlotInventory())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] != nil, "a persisted record says which format it is in")
        let newer = Data("{\"schemaVersion\":99,\"slots\":[]}".utf8)
        let error = #expect(throws: VMSlotError.self) { try JSONDecoder().decode(VMSlotInventory.self, from: newer) }
        #expect(error == .corruptInventory(reason: .unsupportedSchemaVersion(99)))
    }

    @Test func aPresetNeedsPositiveResources() throws {
        #expect(ResourcePreset(name: "x", memoryBytes: 0, cpuCount: 4, diskBytes: 1, verification: .planBaseline) == nil)
        #expect(ResourcePreset(name: "x", memoryBytes: 1, cpuCount: 0, diskBytes: 1, verification: .planBaseline) == nil)
        #expect(ResourcePreset(name: "", memoryBytes: 1, cpuCount: 1, diskBytes: 1, verification: .planBaseline) == nil)
        #expect(ResourcePreset(name: "x", memoryBytes: 1, cpuCount: 1, diskBytes: 1, verification: .planBaseline) != nil)
        let bad = Data(#"{"name":"x","memoryBytes":0,"cpuCount":4,"diskBytes":1,"verification":"planBaseline"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ResourcePreset.self, from: bad) }
    }

    @Test func anUnreadableEnvironmentRecordIsActionable() throws {
        #expect(throws: EnvironmentRecordError.malformed) { try DevelopmentEnvironment.decode(Data("nope".utf8)) }
        let environment = DevelopmentEnvironment(name: "Dev Mac")
        let data = try JSONEncoder().encode(environment)
        #expect(try DevelopmentEnvironment.decode(data) == environment)
        for error in [EnvironmentRecordError.malformed, .unsupportedSchemaVersion(9)] {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryMessage.isEmpty)
        }
    }

    @Test func aGuestDiskIsAlwaysPositive() throws {
        let preset = ResourcePreset.recommended
        #expect(DevelopmentEnvironment(name: "Dev Mac", preset: preset, guestDiskBytes: 0).guestDiskBytes == preset.diskBytes, "a zero override means the preset's capacity")
        var environment = DevelopmentEnvironment(name: "Dev Mac", preset: preset)
        let refused = environment.setGuestDiskBytes(0)
        #expect(refused == false)
        #expect(environment.guestDiskBytes == preset.diskBytes, "a refused resize changes nothing")
        let resized = environment.setGuestDiskBytes(preset.diskBytes * 2)
        #expect(resized)
        #expect(environment.guestDiskBytes == preset.diskBytes * 2)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(environment)) as? [String: Any])
        json["guestDiskBytes"] = 0
        let zeroed = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: EnvironmentRecordError.malformed) { try DevelopmentEnvironment.decode(zeroed) }
    }

    @Test func aRecordFromANewerGuesthouseIsRecognizedEvenWhenItsShapeChanged() throws {
        // The version is read before the record, so a newer format that renamed a field is
        // reported as "written by a newer Guesthouse", not as damage.
        let newer = Data(#"{"schemaVersion":99,"id":"nope","renamedField":true}"#.utf8)
        #expect(throws: EnvironmentRecordError.unsupportedSchemaVersion(99)) { try DevelopmentEnvironment.decode(newer) }
        #expect(throws: EnvironmentRecordError.malformed) { try DevelopmentEnvironment.decode(Data(#"{"schemaVersion":1}"#.utf8)) }
    }

    @Test func aPersistedSchemaVersionMustBePositive() {
        for value in ["0", "-3"] {
            #expect(throws: DecodingError.self, "version \(value)") { try JSONDecoder().decode(SchemaVersion.self, from: Data(value.utf8)) }
            let inventory = Data("{\"schemaVersion\":\(value),\"slots\":[]}".utf8)
            #expect(throws: VMSlotError.self, "inventory \(value)") { try JSONDecoder().decode(VMSlotInventory.self, from: inventory) }
        }
    }

    @Test func aNewerRecordIsNotOfferedARebuild() {
        let newer = VMSlotError.corruptInventory(reason: .unsupportedSchemaVersion(99))
        #expect(newer.recoveryMessage.contains("Update Guesthouse"))
        #expect(!newer.recoveryMessage.contains("rebuild the record"), "rebuilding here would discard what the newer format keeps")
        #expect(VMSlotError.corruptInventory(reason: .malformed).recoveryMessage.contains("rebuild"))
    }

    @Test func structuralDecodeFailuresAreAlsoActionable() {
        for json in ["{}", "{\"slots\":3}", "{\"slots\":[{\"environmentID\":\"not-a-uuid\"}]}"] {
            let error = #expect(throws: VMSlotError.self, "\(json)") {
                try JSONDecoder().decode(VMSlotInventory.self, from: Data(json.utf8))
            }
            #expect(error == .corruptInventory(reason: .malformed), "\(json)")
            #expect(error?.recoveryMessage.isEmpty == false)
        }
    }

    @Test func decodingDuplicateEnvironmentsIsAnActionableError() throws {
        let slots = [a, a].map { VMSlotInventory.Slot(environmentID: $0) }
        let data = try JSONEncoder().encode(["slots": slots])
        let error = #expect(throws: VMSlotError.self) {
            try JSONDecoder().decode(VMSlotInventory.self, from: data)
        }
        #expect(error == .corruptInventory(reason: .duplicateEnvironment))
        #expect(error?.recoveryMessage.contains("inspect") == true)
    }
}
