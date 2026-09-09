import Foundation
import GuesthouseCore
import Testing

@Suite struct JournalHistoryTests {
    let id = OperationID()
    let environment = EnvironmentID()

    func record(_ outcome: JournalRecord.Outcome, id: OperationID? = nil,
                environment: EnvironmentID? = nil, operation: JournalOperation = .provision(stage: .sshPaired)) -> JournalRecord {
        JournalRecord(id: id ?? self.id, environmentID: environment ?? self.environment,
                      operation: operation, timestamp: Date(timeIntervalSince1970: 1_800_000_000), outcome: outcome)
    }

    func rejected(_ record: JournalRecord, by history: inout JournalHistory, as error: StateStoreError) {
        let records = history.records
        let inFlight = history.inFlight
        #expect(throws: error) { try history.validateAppend(record) }
        #expect(throws: error) { try history.append(record) }
        #expect(history.records == records)
        #expect(history.inFlight == inFlight)
    }

    @Test func validationDoesNotReserveOrPublishAnOperation() throws {
        var history = JournalHistory()
        let start = record(.started)
        try history.validateAppend(start)
        try history.validateAppend(start)
        #expect(history.records.isEmpty)
        #expect(history.inFlight.isEmpty)
        try history.append(start)
        #expect(history.records == [start])
        #expect(history.inFlight == [id: start])
    }

    @Test(arguments: JournalOperation.allCases)
    func eachSupportedOperationRetainsItsDetails(operation: JournalOperation) throws {
        var history = JournalHistory()
        let start = record(.started, operation: operation)
        let done = record(.completed, operation: operation)
        try history.append(start)
        try history.append(done)
        #expect(history.records == [start, done])
        #expect(history.inFlight.isEmpty)
    }

    @Test(arguments: [JournalRecord.Outcome.unknown, .failed(.canceled), .checkpoint(.sshPaired)])
    func unresolvedRecordsBlockANewMutationUntilReconciled(outcome: JournalRecord.Outcome) throws {
        var history = JournalHistory()
        try history.append(record(.started))
        let pending = record(outcome)
        try history.append(pending)
        #expect(history.inFlight == [id: pending])
        let next = record(.started, id: OperationID())
        rejected(next, by: &history, as: .operationUnresolved(id))
        try history.append(record(.notApplied))
        try history.append(next)
        #expect(history.records.count == 4)
        #expect(history.inFlight == [next.id: next])
    }

    @Test func anUnknownFailureRetainsItsIdentityUntilInspection() throws {
        var history = JournalHistory()
        try history.append(record(.started))
        let failed = record(.failed(.operationOutcomeUnknown(id)))
        try history.append(failed)
        #expect(history.inFlight == [id: failed])
        rejected(record(.started, id: OperationID()), by: &history, as: .operationUnresolved(id))
        try history.append(record(.completed))
        #expect(history.inFlight.isEmpty)
    }

    @Test func independentEnvironmentsDoNotBlockOneAnother() throws {
        var history = JournalHistory()
        let first = record(.started)
        let second = record(.started, id: OperationID(), environment: EnvironmentID())
        try history.append(first)
        try history.append(second)
        #expect(history.inFlight == [first.id: first, second.id: second])
        try history.append(record(.completed))
        #expect(history.inFlight == [second.id: second])
    }

    @Test(arguments: [JournalRecord.Outcome.completed, .notApplied, .failed(.runtimeMissing)],
          [JournalRecord.Outcome.started, .checkpoint(.sshPaired), .unknown, .completed, .failed(.canceled)])
    func noRecordCanReviveASettledOperation(terminal: JournalRecord.Outcome, late: JournalRecord.Outcome) throws {
        var history = JournalHistory()
        try history.append(record(.started))
        try history.append(record(terminal))
        rejected(record(late), by: &history, as: .inconsistentRecord(id))
        let next = record(.started, id: OperationID())
        try history.append(next)
        #expect(history.inFlight == [next.id: next])
    }

    @Test(arguments: [JournalRecord.Outcome.completed, .notApplied, .unknown, .checkpoint(.sshPaired), .failed(.canceled)])
    func aFollowupCannotInventItsStart(outcome: JournalRecord.Outcome) {
        var history = JournalHistory()
        rejected(record(outcome), by: &history, as: .inconsistentRecord(id))
    }

    @Test func anOperationIDCannotBeStartedTwiceOrReusedForAnotherEnvironment() throws {
        var history = JournalHistory()
        try history.append(record(.started))
        rejected(record(.started), by: &history, as: .inconsistentRecord(id))
        rejected(record(.started, environment: EnvironmentID()), by: &history, as: .inconsistentRecord(id))
        try history.append(record(.completed))
        rejected(record(.started, environment: EnvironmentID()), by: &history, as: .inconsistentRecord(id))
    }

    @Test func followupIdentityMustMatchBothEnvironmentAndOperationDetail() throws {
        var history = JournalHistory()
        try history.append(record(.started))
        rejected(record(.completed, environment: EnvironmentID()), by: &history, as: .inconsistentRecord(id))
        rejected(record(.completed, operation: .provision(stage: .guestSecured)), by: &history, as: .inconsistentRecord(id))
        let other = OperationID()
        rejected(record(.completed, id: other), by: &history, as: .inconsistentRecord(other))
        try history.append(record(.completed))
        #expect(history.records.count == 2)
    }

    @Test func contradictoryReportedIdentitiesCannotChangeTheHistory() throws {
        var history = JournalHistory()
        try history.append(record(.started))
        rejected(record(.failed(.operationOutcomeUnknown(OperationID()))), by: &history, as: .inconsistentRecord(id))
        rejected(record(.failed(.guestNotReachable(EnvironmentID()))), by: &history, as: .inconsistentRecord(id))
        rejected(record(.failed(.hostKeyChanged(EnvironmentID()))), by: &history, as: .inconsistentRecord(id))
        rejected(record(.checkpoint(.guestSecured)), by: &history, as: .inconsistentRecord(id))
        try history.append(record(.checkpoint(.sshPaired)))
        #expect(history.records.count == 2)
    }

    @Test func repairKindIsPartOfTheTrackedOperation() throws {
        var history = JournalHistory()
        try history.append(record(.started, operation: .repair(kind: .credentials)))
        rejected(record(.completed, operation: .repair(kind: .runtime)), by: &history, as: .inconsistentRecord(id))
        try history.append(record(.completed, operation: .repair(kind: .credentials)))
        #expect(history.inFlight.isEmpty)
    }

    @Test func aStagedReplayCopyDoesNotChangeThePublishedHistory() throws {
        var published = JournalHistory()
        try published.append(record(.started))
        var staged = published
        try staged.append(record(.unknown))
        rejected(record(.started, id: OperationID()), by: &staged, as: .operationUnresolved(id))
        #expect(published.records.count == 1)
        #expect(published.inFlight[id]?.outcome == .started)
        #expect(staged.records.count == 2)
        #expect(staged.inFlight[id]?.outcome == .unknown)
    }
}
