import Darwin
import Foundation
import GuesthouseCore

/// Retains #57's journal transaction in the runtime boundary (MVP-PLAN.md §3, issue #76).
/// One exclusive file lock spans refresh, validation, tail repair, write and BOTH barriers.
/// Nothing here starts a VM operation or proves an interrupted operation did not execute.
enum StateJournalAppend {
    static func append(
        _ record: JournalRecord, to anchor: StateDirectoryAnchor,
        cached: StateJournalCache, hooks: StateStoreHooks
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
            return try anchor.withDescriptor { directory in
                guard let candidate = try StateFileEntry.withDescriptor(
                    in: directory, access: .writeJournal, permissionBarrier: hooks.permission,
                    validateDirectory: { try anchor.verifyCurrent(version: $0) }, body: { descriptor in
                    let current = try cached.refreshed(descriptor, read: hooks.journalRead)
                    try current.history.validateAppend(record)
                    if current.unterminatedRecord { line.insert(0x0A, at: line.startIndex) }
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
                    let written = try StateFileIO.version(descriptor, name: .journal)
                    let directoryVersion = try anchor.verifyCurrent()
                    try synchronize(descriptor, name: .journal, barrier: hooks.journalFile)
                    try StateFileEntry.verifyCurrent(descriptor, in: directory, access: .writeJournal, version: written)
                    try anchor.verifyCurrent(version: directoryVersion)
                    // Every record needs an entry barrier, even when the journal already
                    // exists: a restore can reattach the same inode before our write.
                    try synchronize(directory, name: .stateDirectory, barrier: hooks.directory)
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

    private static func synchronize(
        _ descriptor: Int32, name: StateStoreError.File, barrier: StateStoreHooks.Barrier
    ) throws(StateStoreError) {
        do { try barrier(descriptor, name) }
        catch let failure as StateStoreError { throw failure }
        catch { throw .fileUnwritable(name: name) }
    }
}
