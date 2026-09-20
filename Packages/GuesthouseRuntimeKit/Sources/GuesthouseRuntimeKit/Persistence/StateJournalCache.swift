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

    /// Stage our appended record using ONLY the version checked across both barriers.
    /// This value still must not become the actor's cache until the whole borrow returns.
    func appending(_ record: JournalRecord, bytes: Int, version: StateFileVersion) throws(StateStoreError) -> Self {
        var candidate = self
        let (count, overflow) = byteCount.addingReportingOverflow(bytes)
        guard bytes > 0, !overflow else { throw .fileUnwritable(name: .journal) }
        try candidate.history.append(record)
        candidate.byteCount = count
        candidate.truncatedTail = false
        candidate.unterminatedRecord = false
        candidate.file = version
        return candidate
    }

    func refreshed(
        _ descriptor: Int32,
        read: Reader = { try StateFileIO.readAll($0, from: $1, name: .journal) }
    ) throws(StateStoreError) -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0 else { throw .fileUnreadable(name: .journal) }
        // Metadata timestamps are not unique content generations. Re-read the complete
        // locked file even at equal length/version; never authorize recovery from stale bytes.
        var candidate = Self()
        candidate.file = StateFileVersion(info)
        let fresh: Data
        do { fresh = try read(descriptor, 0) }
        catch let failure as StateStoreError { throw failure }
        catch { throw .fileUnreadable(name: .journal) }
        let chunk = try JournalReplayChunk(fresh)
        candidate.history = chunk.history
        candidate.byteCount = chunk.validatedByteCount
        candidate.truncatedTail = chunk.truncatedTail
        candidate.unterminatedRecord = chunk.unterminatedRecord
        return candidate
    }
}
