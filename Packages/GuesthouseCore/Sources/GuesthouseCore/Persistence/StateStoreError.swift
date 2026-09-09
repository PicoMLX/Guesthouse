import Foundation

/// Closed persistence failures (MVP-PLAN.md §3, ADR 0003). No arbitrary path, reason,
/// underlying error description or raw record can become presentation content.
public enum StateStoreError: Error, Hashable, Sendable, LocalizedError {
    public enum ProtectionFailure: Hashable, Sendable, CaseIterable {
        case symbolicLink, notDirectory, notRegularFile, multipleLinks
        case unreadable, unopenable, permissions, aclUnreadable, changed, ancestryUnresolved
    }

    public enum SnapshotInconsistency: Hashable, Sendable, CaseIterable {
        case duplicateEnvironments, duplicateSlots, slotsDisagree, unknownProvisioningEnvironment
        case environmentVersion, provisioningVersion, checkpointStage, effectCounter
    }

    /// Logical store areas, never user-selected paths or actual filenames.
    public enum File: Hashable, Sendable, CaseIterable {
        case stateDirectory, snapshot, journal

        var label: String {
            switch self {
            case .stateDirectory: "saved-state folder"
            case .snapshot: "environment snapshot"
            case .journal: "operation journal"
            }
        }
    }

    case insecureDirectory(reason: ProtectionFailure)
    case corruptSnapshot
    case inconsistentSnapshot(reason: SnapshotInconsistency)
    case corruptJournal(line: Int)
    /// Unsupported can mean an older prototype or a newer format; never skip the record.
    case unsupportedJournalFormat(line: Int, format: Int)
    case unsupportedSnapshotVersion(found: SchemaVersion, current: SchemaVersion)
    case inconsistentRecord(OperationID)
    case operationUnresolved(OperationID)
    case newerSchemaVersion(found: SchemaVersion, current: SchemaVersion)
    case migrationMissing(from: SchemaVersion)
    case migrationProducedWrongVersion(from: SchemaVersion, produced: SchemaVersion)
    case migrationFailed(from: SchemaVersion)
    case duplicateMigration(from: SchemaVersion)
    case fileUnwritable(name: File)
    case fileUnreadable(name: File)
    /// Writing began, but durability/location could not be confirmed. The cause stays typed;
    /// it is not permission to retry the mutation or recursively render an error transcript.
    indirect case journalWriteUncertain(cause: StateStoreError)
    case unencodable(name: File)

    public var userMessage: String {
        switch self {
        case .insecureDirectory: "Guesthouse could not verify the protection of its saved state."
        case .corruptSnapshot: "The saved list of development Macs could not be read."
        case .inconsistentSnapshot: "The saved development Mac records disagree with one another."
        case .corruptJournal: "The operation journal contains a damaged record."
        case .unsupportedJournalFormat: "This build cannot read the operation journal's record format."
        case .unsupportedSnapshotVersion: "This build cannot read the saved environment snapshot's format."
        case .inconsistentRecord: "A journal record disagrees with the operation it belongs to."
        case .operationUnresolved: "An earlier operation has no confirmed outcome yet."
        case .newerSchemaVersion: "The saved state uses a newer format than this build supports."
        case .migrationMissing: "This build has no supported upgrade for the saved state."
        case .migrationProducedWrongVersion: "A saved-state upgrade produced an unexpected format."
        case .migrationFailed: "The saved-state upgrade could not complete."
        case .duplicateMigration: "This build contains conflicting saved-state upgrades."
        case .fileUnwritable(let file): "Guesthouse could not write its \(file.label)."
        case .fileUnreadable(let file): "Guesthouse could not read its \(file.label)."
        case .journalWriteUncertain: "Guesthouse could not confirm that the journal record was saved."
        case .unencodable(let file): "Guesthouse could not encode its \(file.label)."
        }
    }

    public var recoveryMessage: String {
        switch self {
        case .unsupportedJournalFormat, .unsupportedSnapshotVersion, .newerSchemaVersion, .migrationMissing:
            "Keep the original saved state unchanged and use a build that supports its format."
        case .migrationProducedWrongVersion, .migrationFailed, .duplicateMigration:
            "Keep the original saved state unchanged. Check for a corrected Guesthouse build before trying the upgrade again."
        default:
            "Preserve the saved state and unpublished work. Inspect the actual state before starting or retrying an operation."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unsupportedJournalFormat, .unsupportedSnapshotVersion, .migrationMissing: [.cancel]
        case .newerSchemaVersion, .migrationProducedWrongVersion, .migrationFailed, .duplicateMigration: [.updateApp, .cancel]
        case .fileUnwritable: [.freeDiskSpace, .inspectState, .cancel]
        default: [.inspectState, .cancel]
        }
    }

    public var errorDescription: String? { userMessage }
    public var recoverySuggestion: String? { recoveryMessage }
}
