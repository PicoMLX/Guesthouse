import Foundation
import GuesthouseCore
import Synchronization

/// One service-lifetime metadata owner shared by all authenticated sessions (MVP §3).
/// Starts once, retains the store/lock after loading, and never replays host/guest mutations.
/// Construction and status reads are in-memory only; StateStore schedules filesystem work.
public final class RuntimeStateLoader: Sendable {
    struct LoadedState: Sendable {
        let snapshot: EnvironmentsSnapshot
        let journal: JournalReplay
        let store: StateStore
        let storageDestination: URL?
    }
    private struct State: Sendable {
        var started = false
        var status: RuntimeSavedStateStatus = .loading
        var loaded: LoadedState?
    }
    private let state = Mutex(State())
    private let open: @Sendable () async throws(StateStoreError) -> StateStore

    public convenience init() { self.init(open: StateStore.open) }

    // Package-only fixture injection; GUI requests never supply paths or storage factories.
    init(open: @escaping @Sendable () async throws(StateStoreError) -> StateStore) { self.open = open }

    public var status: RuntimeSavedStateStatus { state.withLock { $0.status } }
    var loadedState: LoadedState? { state.withLock { $0.loaded } }

    /// Called on the bounded read-only worker, never inside the session gate. Missing,
    /// loading or rejected metadata cannot supply a new selection. Every probe rereads facts.
    func hostPreflight() -> PreflightReport {
        let loaded = state.withLock { $0.status == .loaded ? $0.loaded : nil }
        return RuntimeHostPreflight(storageRoot: loaded?.storageDestination,
            expectedVolume: loaded?.snapshot.storageSelection?.volumeID).check()
    }

    /// A second caller does not open another owner or retry a failed load. Failure needs
    /// explicit user-directed recovery and a new service instance, not automatic recreation.
    public func load() async {
        let start = state.withLock { value in
            guard !value.started else { return false }
            value.started = true
            return true
        }
        guard start else { return }
        var opened: StateStore?
        do {
            let store = try await open()
            opened = store
            let snapshot = try await store.loadSnapshot()
            let journal = try await store.replay()
            let destination = snapshot.storageSelection == nil ? nil : try await store.storageDestination()
            let loaded = LoadedState(snapshot: snapshot, journal: journal, store: store, storageDestination: destination)
            state.withLock {
                $0.loaded = loaded
                $0.status = journal.truncatedTail ? .repairRequired : .loaded
            }
        } catch {
            // A partially loaded snapshot must never escape as a usable inventory.
            await opened?.close()
            state.withLock { $0.status = Self.status(for: error) }
        }
    }

    private static func status(for error: StateStoreError) -> RuntimeSavedStateStatus {
        switch error {
        case .unsupportedJournalFormat, .unsupportedSnapshotVersion, .newerSchemaVersion,
             .migrationMissing, .migrationProducedWrongVersion, .migrationFailed, .duplicateMigration:
            .incompatible
        case .corruptSnapshot, .inconsistentSnapshot, .corruptJournal, .inconsistentRecord:
            .repairRequired
        default: .unavailable
        }
    }
}
