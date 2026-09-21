import Darwin
import Foundation
import GuesthouseCore

/// Retained #57 refresh state (MVP-PLAN.md §3), confined to the runtime store's actor.
/// A refresh returns a candidate, never publishes it. The caller holds the file lock and
/// validates the complete descriptor/entry/directory borrow before adopting this value.
struct StateJournalCache {
    static let maximumRecords = 16_384
    typealias Reader = @Sendable (Int32, off_t) throws -> Data
    private(set) var history = JournalHistory()
    private(set) var byteCount = 0
    private(set) var truncatedTail = false
    private(set) var unterminatedRecord = false
    private(set) var file: StateFileVersion?
    private(set) var validatedBytes = Data()

    var replay: JournalReplay {
        JournalReplay(records: history.records, inFlight: history.inFlight, truncatedTail: truncatedTail)
    }

    /// Stage our appended record using ONLY the version checked across both barriers.
    /// This value still must not become the actor's cache until the whole borrow returns.
    func appending(_ record: JournalRecord, bytes: Data, version: StateFileVersion) throws(StateStoreError) -> Self {
        var candidate = self
        let (count, overflow) = byteCount.addingReportingOverflow(bytes.count)
        guard !bytes.isEmpty, !overflow else { throw .fileUnwritable(name: .journal) }
        try candidate.history.append(record)
        candidate.byteCount = count
        candidate.validatedBytes.append(bytes)
        candidate.truncatedTail = false
        candidate.unterminatedRecord = false
        candidate.file = version
        return candidate
    }

    func refreshed(
        _ descriptor: Int32,
        requiringPrefix: Data = Data(),
        didRead: (Data) -> Void = { _ in },
        didFailRead: () -> Void = {},
        read: Reader = { try StateFileIO.readAll($0, from: $1, name: .journal) }
    ) throws(StateStoreError) -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0,
              info.st_size <= off_t(StateFileIO.maximumJournalBytes) else {
            didFailRead()
            throw .fileUnreadable(name: .journal)
        }
        // Metadata timestamps are not unique content generations. Re-read the complete
        // locked file even at equal length/version; never authorize recovery from stale bytes.
        var candidate = Self()
        candidate.file = StateFileVersion(info)
        let fresh: Data
        do { fresh = try read(descriptor, 0) }
        catch let failure as StateStoreError { didFailRead(); throw failure }
        catch { didFailRead(); throw .fileUnreadable(name: .journal) }
        guard fresh.count <= StateFileIO.maximumJournalBytes else {
            didFailRead()
            throw .fileUnreadable(name: .journal)
        }
        var after = stat()
        guard fresh.count == Int(info.st_size), fstat(descriptor, &after) == 0,
              after.st_size == info.st_size, StateFileVersion(after) == StateFileVersion(info) else {
            didFailRead()
            throw .fileUnreadable(name: .journal)
        }
        guard fresh.starts(with: requiringPrefix) else {
            // Conflicting observed bytes may name another interrupted operation. Restoring
            // the old prefix cannot prove that operation never happened.
            didFailRead()
            throw .fileUnreadable(name: .journal)
        }
        didRead(fresh) // Bounded raw evidence survives record-budget or decoding failure.
        try Self.validateBudget(fresh)
        let chunk = try JournalReplayChunk(fresh)
        candidate.history = chunk.history
        candidate.byteCount = chunk.validatedByteCount
        candidate.truncatedTail = chunk.truncatedTail
        candidate.unterminatedRecord = chunk.unterminatedRecord
        candidate.validatedBytes = Data(fresh.prefix(chunk.validatedByteCount))
        return candidate
    }

    /// Check before splitting lines or decoding records, including injected reads. A final
    /// nonempty line counts even when incomplete; no rotation or evidence deletion is implied.
    static func validateBudget(_ data: Data) throws(StateStoreError) {
        guard data.count <= StateFileIO.maximumJournalBytes else { throw .fileUnreadable(name: .journal) }
        var records = data.isEmpty || data.last == 10 ? 0 : 1
        for byte in data where byte == 10 {
            records += 1
            guard records <= maximumRecords else { throw .fileUnreadable(name: .journal) }
        }
    }
}

/// Monotonic evidence, separate from the disposable replay cache. Never reset on a failed
/// read, parse, barrier or outer binding check. Observation is not durability or authorization.
/// The retained raw-byte prefix is bounded by maximumJournalBytes. A torn suffix is not
/// promoted to complete history; only the existing history-aware append repair can replace it.
struct StateJournalObservation {
    private var identity: StateFileIdentity?
    private var prefix = Data()
    private var unboundObservation = false
    private var unreadObservation = false

    mutating func recordUnreadFailure() { unreadObservation = true }

    /// Check before opening, including when the entry is currently missing. Absence cannot
    /// clear an earlier failed borrow whose directory/journal binding was never established.
    func requireReadable() throws(StateStoreError) {
        guard !unreadObservation, !unboundObservation else { throw .fileUnreadable(name: .journal) }
    }

    /// Called before preparation/body entry. Unknown binding cannot later become a new
    /// journal implicitly; it requires explicit recovery outside this owner's lifetime.
    mutating func identify(_ observed: StateFileIdentity?) -> Bool {
        guard let observed else { unboundObservation = true; return false }
        guard !unboundObservation, identity == nil || identity == observed else { return false }
        identity = observed
        return true
    }

    mutating func refreshed(
        _ descriptor: Int32,
        read: StateJournalCache.Reader = { try StateFileIO.readAll($0, from: $1, name: .journal) }
    ) throws(StateStoreError) -> StateJournalCache {
        try requireReadable()
        let current: StateFileIdentity
        do { current = try StateFileIO.version(descriptor, name: .journal).identity }
        catch { unreadObservation = true; throw error }
        guard identify(current) else { throw .fileUnreadable(name: .journal) }
        let candidate = try StateJournalCache().refreshed(descriptor, requiringPrefix: prefix,
            didRead: { prefix = $0 }, didFailRead: { unreadObservation = true }, read: read)
        // Failed I/O may have hidden newer evidence even when an earlier prefix is known.
        // No subsequent read or cache reset can clear that uncertainty for this owner.
        // Even successfully recognized torn bytes remain evidence during ordinary replay.
        // Only the explicit append transaction can authorize removing that exact suffix.
        return candidate
    }

    /// Only after the locked append has validated its record and capacity. The caller must
    /// latch uncertainty if truncation or any subsequent publication check fails; lowering
    /// this prefix alone never authorizes a later retry or confirms an operation outcome.
    mutating func authorizeTailRepair(_ candidate: StateJournalCache) throws(StateStoreError) {
        try requireReadable()
        guard candidate.truncatedTail, prefix.count > candidate.validatedBytes.count,
              prefix.starts(with: candidate.validatedBytes) else { throw .fileUnreadable(name: .journal) }
        prefix = candidate.validatedBytes
    }
}
