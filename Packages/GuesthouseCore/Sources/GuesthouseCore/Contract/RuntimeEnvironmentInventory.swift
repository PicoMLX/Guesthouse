/// Saved card records, not live VM inventory or permission to stop/start/delete (§§2–3).
/// Missing, loading or rejected metadata must never masquerade as an empty available list.
/// Names are private UI data; they are never diagnostic or executable inputs.
public enum RuntimeEnvironmentInventory: Codable, Hashable, Sendable {
    case available([DevelopmentEnvironment])
    case unavailable(RuntimeSavedStateStatus)

    public var isValid: Bool {
        switch self {
        case .unavailable(let status): return status != .loaded
        case .available(let records):
            return records.count <= 2 && Set(records.map(\.id)).count == records.count
                && records.allSatisfy { $0.schemaVersion == .current && $0.name.utf8.count <= 1024 }
        }
    }
}
