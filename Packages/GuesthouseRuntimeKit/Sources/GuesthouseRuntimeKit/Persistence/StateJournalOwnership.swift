import GuesthouseCore
import Synchronization

/// Process-local evidence for every live store retaining the same directory inode.
/// The last lease releases memory, not disk evidence or an unknown operation outcome.
/// Native directory/file locks still guard other processes; this is not a durable registry.
final class StateJournalOwnership: Sendable {
    private struct Entry: Sendable {
        var owners = 0
        var busy = false
        var observation = StateJournalObservation()
        var wasObserved = false
    }
    private static let entries = Mutex<[StateFileIdentity: Entry]>([:])
    private let identity: StateFileIdentity

    init(identity: StateFileIdentity) {
        self.identity = identity
        Self.entries.withLock { entries in
            var entry = entries[identity] ?? Entry()
            entry.owners += 1
            entries[identity] = entry
        }
    }

    /// One synchronous caller borrows the evidence through ALL outer binding checks.
    /// Contention refuses without opening files or poisoning evidence. No I/O, callback,
    /// await or native lock acquisition occurs while the registry Mutex is held.
    func withObservation<Value>(
        _ body: (inout StateJournalObservation, inout Bool) throws(StateStoreError) -> Value
    ) throws(StateStoreError) -> Value {
        let borrowed = Self.entries.withLock { entries -> (StateJournalObservation, Bool)? in
            guard var entry = entries[identity], !entry.busy else { return nil }
            entry.busy = true
            entries[identity] = entry
            return (entry.observation, entry.wasObserved)
        }
        guard let borrowed else { throw .fileUnwritable(name: .journal) }
        var observation = borrowed.0
        var wasObserved = borrowed.1
        defer {
            Self.entries.withLock { entries in
                // This method retains its lease. Keep the CURRENT count: other owners
                // may have opened or closed while the synchronous body was running.
                entries[identity]?.observation = observation
                entries[identity]?.wasObserved = wasObserved
                entries[identity]?.busy = false
            }
        }
        // Write back even on failure: uncertainty and raw prefix observations are sticky.
        return try body(&observation, &wasObserved)
    }

    deinit {
        Self.entries.withLock { entries in
            guard var entry = entries[identity] else { return }
            entry.owners -= 1
            if entry.owners == 0 { entries.removeValue(forKey: identity) }
            else { entries[identity] = entry }
        }
    }
}
