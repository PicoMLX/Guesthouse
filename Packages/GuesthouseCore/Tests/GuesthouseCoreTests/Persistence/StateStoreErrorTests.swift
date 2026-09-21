import Foundation
import GuesthouseCore
import Testing

@Suite struct StateStoreErrorTests {
    @Test(arguments: [
        StateStoreError.insecureDirectory(reason: .symbolicLink), .corruptSnapshot, .storageSelectionChanged,
        .inconsistentSnapshot(reason: .slotsDisagree), .corruptJournal(line: 1),
        .unsupportedJournalFormat(line: 1, format: 1),
        .unsupportedSnapshotVersion(found: SchemaVersion(1)!, current: SchemaVersion(2)!),
        .inconsistentRecord(OperationID()), .operationUnresolved(OperationID()),
        .newerSchemaVersion(found: SchemaVersion(99)!, current: SchemaVersion(2)!),
        .migrationMissing(from: .unversioned),
        .migrationProducedWrongVersion(from: SchemaVersion(1)!, produced: SchemaVersion(3)!),
        .migrationFailed(from: SchemaVersion(1)!), .duplicateMigration(from: SchemaVersion(1)!),
        .fileUnwritable(name: .journal), .fileUnreadable(name: .snapshot),
        .unencodable(name: .snapshot), .journalWriteUncertain(cause: .fileUnwritable(name: .journal)),
    ])
    func everyFailureHasFixedPreservationFirstRecovery(error: StateStoreError) {
        #expect(!error.userMessage.isEmpty)
        #expect(!error.recoveryMessage.isEmpty)
        #expect(!error.recoveryActions.isEmpty)
        #expect(error.errorDescription == error.userMessage)
        #expect(error.recoverySuggestion == error.recoveryMessage)
        #expect(!error.recoveryActions.contains(.deleteEnvironment))
        #expect(!error.recoveryActions.contains(.openSettings))
        #expect(!error.userMessage.contains("nothing was changed"))
    }

    @Test(arguments: [
        (StateStoreError.File.stateDirectory, "Guesthouse could not write its saved-state folder."),
        (.snapshot, "Guesthouse could not write its environment snapshot."),
        (.journal, "Guesthouse could not write its operation journal."),
    ])
    func logicalFileNamesAreGuesthouseOwned(file: StateStoreError.File, expected: String) {
        #expect(StateStoreError.fileUnwritable(name: file).userMessage == expected)
    }

    @Test func operationalIdentitiesAndNestedCausesAreNotInterpolated() {
        let id = OperationID()
        #expect(!StateStoreError.operationUnresolved(id).userMessage.contains(id.description))
        let first = StateStoreError.journalWriteUncertain(cause: .inconsistentRecord(id))
        let nested = StateStoreError.journalWriteUncertain(cause: first)
        #expect(first.userMessage == "Guesthouse could not confirm that the journal record was saved.")
        #expect(nested.userMessage == first.userMessage)
        #expect(nested.recoveryActions == [.inspectState, .cancel])
    }

    @Test(arguments: [1, 2, 99])
    func unsupportedDoesNotAssumeTheJournalIsNewer(format: Int) {
        let error = StateStoreError.unsupportedJournalFormat(line: 5, format: format)
        #expect(error.userMessage == "This build cannot read the operation journal's record format.")
        #expect(error.recoveryMessage == "Keep the original saved state unchanged and use a build that supports its format.")
        #expect(error.recoveryActions == [.cancel])
    }
}
