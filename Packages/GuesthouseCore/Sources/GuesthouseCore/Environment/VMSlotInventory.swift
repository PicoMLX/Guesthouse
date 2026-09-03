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

    /// Reserves a slot for `id`. Reserving an environment that already holds a slot is a no-op,
    /// so a retried operation cannot consume a second slot.
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

    /// Frees the slot held by `id`. Releasing an unknown environment is a no-op.
    public mutating func release(_ id: EnvironmentID) {
        slots.removeAll { $0.environmentID == id }
    }
}

public enum VMSlotError: Error, Hashable, Sendable {
    case inventoryFull(maximum: Int)
    case unknownEnvironment(EnvironmentID)
}

extension VMSlotError: LocalizedError {
    /// Plain-language explanation for the user.
    public var userMessage: String {
        switch self {
        case .inventoryFull(let maximum):
            "Guesthouse manages at most \(maximum) development Macs, including stopped and preserved ones."
        case .unknownEnvironment(let id):
            "No development Mac with the identifier \(id) is registered on this Mac."
        }
    }

    /// What the user can do about it.
    public var recoveryMessage: String {
        switch self {
        case .inventoryFull:
            "Delete or export an existing development Mac to make room for another."
        case .unknownEnvironment:
            "Check the environment list; the record may have been removed by a repair or deletion."
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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([Slot].self, forKey: .slots)
        guard decoded.count <= Self.maximumSlots else {
            throw DecodingError.dataCorruptedError(
                forKey: .slots, in: container,
                debugDescription: "\(decoded.count) slots exceed the maximum of \(Self.maximumSlots)"
            )
        }
        guard Set(decoded.map(\.environmentID)).count == decoded.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .slots, in: container,
                debugDescription: "duplicate environment identifiers in slot inventory"
            )
        }
        slots = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slots, forKey: .slots)
    }
}
