import Foundation

/// Enforces the app's own limit of two installed VM bundles (MVP-PLAN.md §1).
///
/// Stopped and recovery-preserved VMs still occupy a slot; only deletion frees one. This is a
/// product constraint the app can enforce on its own inventory. It is not a license check and
/// says nothing about other virtualization software on the host.
public struct VMSlotInventory: Hashable, Sendable {
    public static let maximumSlots = 2

    public enum SlotState: String, Codable, Hashable, Sendable {
        /// A normal environment, running or stopped.
        case active
        /// Kept after a failed repair or an incomplete export; still counts against the cap.
        case preserved
    }

    public struct Slot: Codable, Hashable, Sendable {
        public let environmentID: EnvironmentID
        public var state: SlotState

        public init(environmentID: EnvironmentID, state: SlotState = .active) {
            self.environmentID = environmentID
            self.state = state
        }
    }

    public private(set) var slots: [Slot]

    public init() {
        slots = []
    }

    public var occupiedSlots: Int { slots.count }
    public var availableSlots: Int { Self.maximumSlots - slots.count }
    public var isFull: Bool { slots.count >= Self.maximumSlots }

    public func state(of id: EnvironmentID) -> SlotState? {
        slots.first { $0.environmentID == id }?.state
    }

    /// Reserves a slot for `id`. Reserving an environment that already holds a slot is a no-op
    /// (its state, active or preserved, is unchanged), so a retried operation cannot consume a
    /// second slot. Use `markActive` to bring a preserved environment back.
    public mutating func reserve(_ id: EnvironmentID) throws(VMSlotError) {
        if slots.contains(where: { $0.environmentID == id }) { return }
        guard !isFull else { throw .inventoryFull(maximum: Self.maximumSlots) }
        slots.append(Slot(environmentID: id))
    }

    /// Marks an environment as preserved. It keeps its slot.
    public mutating func markPreserved(_ id: EnvironmentID) throws(VMSlotError) {
        guard let index = slots.firstIndex(where: { $0.environmentID == id }) else {
            throw .unknownEnvironment(id)
        }
        slots[index].state = .preserved
    }

    /// Returns a preserved environment to normal use after a repair or recovery succeeded.
    /// The slot is never released in between, so the bundle is never unaccounted for.
    public mutating func markActive(_ id: EnvironmentID) throws(VMSlotError) {
        guard let index = slots.firstIndex(where: { $0.environmentID == id }) else {
            throw .unknownEnvironment(id)
        }
        slots[index].state = .active
    }

    /// Frees the slot held by `id`. Releasing an unknown environment is a no-op.
    public mutating func release(_ id: EnvironmentID) {
        slots.removeAll { $0.environmentID == id }
    }
}

public enum VMSlotError: Error, Hashable, Sendable {
    case inventoryFull(maximum: Int)
    case unknownEnvironment(EnvironmentID)
    /// The persisted inventory could not be used: more slots than exist, or the same
    /// environment listed twice.
    case corruptInventory(reason: Reason)

    public enum Reason: Hashable, Sendable {
        case tooManySlots(found: Int, maximum: Int)
        case duplicateEnvironment
        /// The file is not a slot inventory at all: a missing or mistyped field, an invalid
        /// identifier, or an unknown slot state.
        case malformed
    }
}

extension VMSlotError: LocalizedError {
    /// Plain-language explanation for the user.
    public var userMessage: String {
        switch self {
        case .inventoryFull(let maximum):
            "Guesthouse manages at most \(maximum) development Macs, including stopped and preserved ones."
        case .unknownEnvironment(let id):
            "No development Mac with the identifier \(id) is registered on this Mac."
        case .corruptInventory(.tooManySlots(let found, let maximum)):
            "Guesthouse's record of development Macs lists \(found) of them, more than the \(maximum) it manages, so it cannot be used as it is."
        case .corruptInventory(.duplicateEnvironment):
            "Guesthouse's record of development Macs lists the same one twice, so it cannot be used as it is."
        case .corruptInventory(.malformed):
            "Guesthouse's record of development Macs could not be read."
        }
    }

    /// What the user can do about it.
    public var recoveryMessage: String {
        switch self {
        case .inventoryFull:
            "Export any unpublished work from a development Mac you no longer need, then delete it to make room. Exporting alone does not free a slot."
        case .unknownEnvironment:
            "Check the environment list; the record may have been removed by a repair or deletion."
        case .corruptInventory:
            "Guesthouse will inspect the virtual machines that actually exist and rebuild the record from them; nothing is started or deleted until it has."
        }
    }


    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }
}

extension VMSlotInventory: Codable {
    private enum CodingKeys: String, CodingKey {
        case slots
    }

    public init(from decoder: any Decoder) throws {
        // Every structural failure is reported as a corrupt inventory, so a caller always has
        // a message and a way forward rather than a decoder's internal complaint.
        let decoded: [Slot]
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            decoded = try container.decode([Slot].self, forKey: .slots)
        } catch {
            throw VMSlotError.corruptInventory(reason: .malformed)
        }
        // A corrupt inventory is a state the user can be told about and recover from, so it
        // is reported as `VMSlotError` rather than as a decoder's internal complaint.
        guard decoded.count <= Self.maximumSlots else {
            throw VMSlotError.corruptInventory(reason: .tooManySlots(found: decoded.count, maximum: Self.maximumSlots))
        }
        guard Set(decoded.map(\.environmentID)).count == decoded.count else {
            throw VMSlotError.corruptInventory(reason: .duplicateEnvironment)
        }
        slots = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
    }
}
