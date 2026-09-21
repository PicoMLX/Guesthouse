import Synchronization

/// Process-local evidence shared by live stores for the same retained directory inode.
/// This is not durable state, a cross-process lock, or authority to recover missing bytes.
/// Registry critical sections only update counters/flags; no IO, callbacks or awaits occur.
final class StateSnapshotObservation: Sendable {
    private struct Entry: Sendable {
        var owners = 0
        var observed = false
    }
    private static let entries = Mutex<[StateFileIdentity: Entry]>([:])
    private let identity: StateFileIdentity

    init(identity: StateFileIdentity) {
        self.identity = identity
        Self.entries.withLock { entries in
            entries[identity, default: Entry()].owners += 1
        }
    }

    var wasObserved: Bool {
        Self.entries.withLock { $0[identity]?.observed == true }
    }

    func record() {
        Self.entries.withLock { $0[identity]?.observed = true }
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
