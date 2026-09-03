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

    @Test func markingUnknownEnvironmentPreservedFails() {
        var inventory = VMSlotInventory()
        #expect(throws: VMSlotError.unknownEnvironment(a)) {
            try inventory.markPreserved(a)
        }
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

    @Test func decodingMoreThanMaximumSlotsFails() throws {
        let slots = [a, b, c].map { VMSlotInventory.Slot(environmentID: $0) }
        let data = try JSONEncoder().encode(["slots": slots])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VMSlotInventory.self, from: data)
        }
    }

    @Test func decodingDuplicateEnvironmentsFails() throws {
        let slots = [a, a].map { VMSlotInventory.Slot(environmentID: $0) }
        let data = try JSONEncoder().encode(["slots": slots])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VMSlotInventory.self, from: data)
        }
    }
}
