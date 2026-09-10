import Darwin
import Foundation
import GuesthouseCore

/// Retained #57 refresh state (MVP-PLAN.md §3), confined to the runtime store's actor.
/// A refresh returns a candidate, never publishes it. The caller holds the file lock and
/// validates the complete descriptor/entry/directory borrow before adopting this value.
struct StateJournalCache {
    typealias Reader = @Sendable (Int32, off_t) throws -> Data
    private(set) var history = JournalHistory()
    private(set) var byteCount = 0
    private(set) var truncatedTail = false
    private(set) var unterminatedRecord = false
    private(set) var file: StateFileVersion?

    var replay: JournalReplay {
        JournalReplay(records: history.records, inFlight: history.inFlight, truncatedTail: truncatedTail)
    }

    func refreshed(
        _ descriptor: Int32,
        read: Reader = { try StateFileIO.readAll($0, from: $1, name: .journal) }
    ) throws(StateStoreError) -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0 else { throw .fileUnreadable(name: .journal) }
        let version = StateFileVersion(info)
        var candidate = self
        // Rewrites, replacement, permission repair and same-inode reattachment invalidate
        // previous bytes. Only our own fully verified writes may retain a known prefix.
        if candidate.file != version || off_t(candidate.byteCount) > info.st_size {
            candidate = Self()
            candidate.file = version
        }
        if off_t(candidate.byteCount) == info.st_size {
            candidate.truncatedTail = false
            // An unchanged complete record may still lack its separator. Do not clear this
            // flag on an empty read, or a subsequent append would fuse two records.
            return candidate
        }
        let fresh: Data
        do { fresh = try read(descriptor, off_t(candidate.byteCount)) }
        catch let failure as StateStoreError { throw failure }
        catch { throw .fileUnreadable(name: .journal) }
        let chunk = try JournalReplayChunk(fresh, following: candidate.history)
        candidate.history = chunk.history
        candidate.byteCount += chunk.validatedByteCount
        candidate.truncatedTail = chunk.truncatedTail
        candidate.unterminatedRecord = chunk.unterminatedRecord
        return candidate
    }
}
