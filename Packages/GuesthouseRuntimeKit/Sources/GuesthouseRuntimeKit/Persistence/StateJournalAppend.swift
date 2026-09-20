import Darwin
import Foundation
import GuesthouseCore

/// Retains #57's journal transaction in the runtime boundary (MVP-PLAN.md §3, issue #76).
/// One exclusive file lock spans refresh, validation, tail repair, write and BOTH barriers.
/// Nothing here starts a VM operation or proves an interrupted operation did not execute.
enum StateJournalAppend {
    static func append(
        _ record: JournalRecord, to anchor: StateDirectoryAnchor,
        cached: StateJournalCache, hooks: StateStoreHooks,
        requireExisting: Bool = false, didObserve: () -> Void = {}
    ) throws(StateStoreError) -> StateJournalCache {
        var line: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            line = try encoder.encode(record)
        } catch { throw .unencodable(name: .journal) }
        line.append(0x0A)

        // This flag surrounds the COMPLETE borrow, including its outer post-checks.
        // Tail truncation also changes disk state; a later failure must not claim no write.
        var writeAttempted = false
        do {
            // Shares the snapshot/first-volume-selection transaction boundary. Contention
            // refuses before opening or creating a journal; it never waits or retries.
            return try anchor.withPublicationOwnership(for: .journal) { directory in
                guard let candidate = try StateFileEntry.withDescriptor(
                    in: directory, access: .writeJournal, requireExisting: requireExisting,
                    permissionBarrier: hooks.permission, didObserve: didObserve,
                    validateDirectory: { try anchor.verifyCurrent(version: $0) }, body: { descriptor in
                    let current = try cached.refreshed(descriptor, read: hooks.journalRead)
                    try current.history.validateAppend(record)
                    if current.unterminatedRecord { line.insert(0x0A, at: line.startIndex) }
                    // Capacity refusal must precede any repair/write attempt. Do not produce
                    // a journal that our bounded replay cannot read on the next launch.
                    try requireCapacity(bytes: current.byteCount, records: current.history.records.count,
                                        additionalBytes: line.count)
                    let expectedLength = current.byteCount + line.count // Capacity check makes this bounded.
                    if current.truncatedTail {
                        writeAttempted = true
                        guard ftruncate(descriptor, off_t(current.byteCount)) == 0 else {
                            throw StateStoreError.fileUnwritable(name: .journal)
                        }
                    }
                    guard lseek(descriptor, 0, SEEK_END) >= 0 else {
                        throw StateStoreError.fileUnwritable(name: .journal)
                    }
                    writeAttempted = true
                    do { try hooks.journalWrite(descriptor, line) }
                    catch let failure as StateStoreError { throw failure }
                    catch { throw StateStoreError.fileUnwritable(name: .journal) }
                    try requireLength(descriptor, expected: expectedLength)
                    let written = try StateFileIO.version(descriptor, name: .journal)
                    try requireBytes(descriptor, from: current.byteCount, expected: line)
                    try requireHistory(descriptor, expected: current.history.records + [record])
                    try StateFileEntry.verifyCurrent(descriptor, in: directory, access: .writeJournal, version: written)
                    let directoryVersion = try anchor.verifyCurrent()
                    try synchronize(descriptor, name: .journal, barrier: hooks.journalFile)
                    try requireLength(descriptor, expected: expectedLength)
                    try requireBytes(descriptor, from: current.byteCount, expected: line)
                    try requireHistory(descriptor, expected: current.history.records + [record])
                    try StateFileEntry.verifyCurrent(descriptor, in: directory, access: .writeJournal, version: written)
                    try anchor.verifyCurrent(version: directoryVersion)
                    // Every record needs an entry barrier, even when the journal already
                    // exists: a restore can reattach the same inode before our write.
                    try synchronize(directory, name: .stateDirectory, barrier: hooks.directory)
                    try requireLength(descriptor, expected: expectedLength)
                    try requireBytes(descriptor, from: current.byteCount, expected: line)
                    try requireHistory(descriptor, expected: current.history.records + [record])
                    try StateFileEntry.verifyCurrent(descriptor, in: directory, access: .writeJournal, version: written)
                    try anchor.verifyCurrent(version: directoryVersion)
                    return try current.appending(record, bytes: line.count, version: written)
                }) else { throw StateStoreError.fileUnwritable(name: .journal) }
                return candidate
            }
        } catch {
            if writeAttempted { throw .journalWriteUncertain(cause: error) }
            throw error
        }
    }

    /// Verify the actual written range, including a required separator, before publishing an
    /// OperationID/cache. Equal length/version alone cannot attest the append's contents.
    private static func requireBytes(_ descriptor: Int32, from offset: Int, expected: Data) throws(StateStoreError) {
        guard try StateFileIO.readAll(descriptor, from: off_t(offset), name: .journal) == expected else {
            throw .fileUnwritable(name: .journal)
        }
    }

    /// Checking only our appended range misses a rewritten prior operation. Revalidate the
    /// complete bounded history at every publication boundary, then check binding/version.
    private static func requireHistory(_ descriptor: Int32, expected: [JournalRecord]) throws(StateStoreError) {
        let observed = try StateJournalCache().refreshed(descriptor)
        guard !observed.truncatedTail, !observed.unterminatedRecord,
              observed.history.records == expected else { throw .fileUnwritable(name: .journal) }
    }

    private static func requireLength(_ descriptor: Int32, expected: Int) throws(StateStoreError) {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size == off_t(expected) else {
            throw .fileUnwritable(name: .journal)
        }
    }

    static func requireCapacity(bytes: Int, records: Int, additionalBytes: Int) throws(StateStoreError) {
        guard bytes >= 0, bytes <= StateFileIO.maximumJournalBytes,
              additionalBytes >= 0, additionalBytes <= StateFileIO.maximumJournalBytes - bytes,
              records >= 0, records < StateJournalCache.maximumRecords else {
            throw .fileUnwritable(name: .journal)
        }
    }

    private static func synchronize(
        _ descriptor: Int32, name: StateStoreError.File, barrier: StateStoreHooks.Barrier
    ) throws(StateStoreError) {
        do { try barrier(descriptor, name) }
        catch let failure as StateStoreError { throw failure }
        catch { throw .fileUnwritable(name: name) }
    }
}
