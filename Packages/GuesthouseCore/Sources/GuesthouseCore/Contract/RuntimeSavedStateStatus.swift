/// Startup metadata status shared by the runtime and GUI (MVP §3, ADR 0004).
/// No case establishes VM readiness, operation admission, or permission to discard work.
/// This closed optional version-query field contains no paths, records or raw error text.
public enum RuntimeSavedStateStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case loading, loaded, repairRequired, incompatible, unavailable

    public var userMessage: String {
        switch self {
        case .loading: "Guesthouse is loading saved environment metadata."
        case .loaded: "Saved environment metadata is loaded."
        case .repairRequired: "Saved environment metadata needs inspection and repair."
        case .incompatible: "This build cannot read the saved environment metadata."
        case .unavailable: "Guesthouse could not open its saved environment metadata."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .loading: "Check the connection again to see the loading result."
        case .loaded: "Development Macs and unfinished operations still need inspection before new work can start."
        case .repairRequired: "Keep saved files and VM disks unchanged. Inspect the interrupted operation before repairing metadata."
        case .incompatible: "Keep saved files unchanged and use a compatible Guesthouse build."
        case .unavailable: "If Guesthouse has not been set up, storage setup is still required. Otherwise, close other runtime instances and inspect saved storage before reopening Guesthouse."
        }
    }
}
