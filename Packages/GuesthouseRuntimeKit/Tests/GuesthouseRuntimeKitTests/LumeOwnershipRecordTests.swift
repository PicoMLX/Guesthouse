import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

struct LumeOwnershipRecordTests {
    let owner = LumeOwnershipIdentity(rootDevice: 1, rootInode: 42, operationID: UUID(),
                                      serviceEpoch: UUID(), generation: UUID())

    func running() throws -> LumeOwnershipRecord {
        try LumeOwnershipRecord(reserving: owner).registeringLaunch(UUID(), owner: owner)
    }

    // This is synthetic evidence for the pure reducer, not an OS inspection implementation.
    func inspection(_ record: LumeOwnershipRecord,
                    conclusion: LumeOwnedSetInspection.Conclusion = .entireOwnedSetQuiescent) -> LumeOwnedSetInspection {
        LumeOwnedSetInspection(identity: record.identity, revision: record.revision,
                               attemptIDs: record.attemptIDs, conclusion: conclusion)
    }

    @Test func noLaunchCanFinishButSettlementIsTerminal() throws {
        let record = LumeOwnershipRecord(reserving: owner)
        let settled = try record.finishing(owner: owner)
        #expect(settled.phase == .settled)
        #expect(settled.revision == 1)
        #expect(try settled.recoveringAfterRestart() == settled)
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try settled.finishing(owner: owner) }
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try settled.registeringLaunch(UUID(), owner: owner) }
    }

    @Test func launchIntentMustStayOutstandingUntilWholeSetInspection() throws {
        let record = try running()
        #expect(record.phase == .executing)
        #expect(record.pendingAttempts == record.attemptIDs)
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try record.finishing(owner: owner) }
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try record.registeringLaunch(UUID(), owner: owner) }

        let observed = try record.accepting(inspection(record))
        #expect(observed.phase == .reserved)
        #expect(observed.pendingAttempts.isEmpty)
        #expect(observed.attemptIDs == record.attemptIDs)
        #expect(try observed.finishing(owner: owner).phase == .settled)
    }

    @Test(arguments: LumeCleanupObservation.allCases)
    func legacyObservationsNeverReleaseOwnership(_ observation: LumeCleanupObservation) throws {
        let record = try running()
        let quarantined = try record.recording(observation, owner: owner)
        #expect(quarantined.phase == .quarantined(observation.reason))
        #expect(quarantined.pendingAttempts == record.pendingAttempts)
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try quarantined.finishing(owner: owner) }
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try quarantined.registeringLaunch(UUID(), owner: owner) }
    }

    @Test(arguments: LumeQuarantineReason.allCases)
    func quarantineNeedsFreshInspectionEvenWhenNoLaunchWasRecorded(_ reason: LumeQuarantineReason) throws {
        let record = try LumeOwnershipRecord(reserving: owner).quarantining(reason, owner: owner)
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try record.finishing(owner: owner) }
        let settled = try record.accepting(inspection(record))
        #expect(settled.phase == .settled, "inspection settles; it never resumes an interrupted operation")
    }

    @Test(arguments: [false, true])
    func restartBlocksReservationsAndSpawnAttachGaps(launched: Bool) throws {
        let record = try launched ? running() : LumeOwnershipRecord(reserving: owner)
        let recovered = try record.recoveringAfterRestart()
        #expect(recovered.phase == .quarantined(.restarted))
        #expect(recovered.revision == record.revision + 1)
        #expect(recovered.attemptIDs == record.attemptIDs)
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try recovered.finishing(owner: owner) }
        #expect(throws: LumeOwnershipFailure.staleInspection) { try recovered.accepting(inspection(record)) }
    }

    @Test func inspectionMustCoverEveryAttemptAndExactRevision() throws {
        let first = try running()
        let quiet = try first.accepting(inspection(first))
        let second = try quiet.registeringLaunch(UUID(), owner: owner)
        #expect(throws: LumeOwnershipFailure.staleInspection) { try second.accepting(inspection(first)) }
        let incomplete = LumeOwnedSetInspection(identity: owner, revision: second.revision,
                                               attemptIDs: first.attemptIDs, conclusion: .entireOwnedSetQuiescent)
        #expect(throws: LumeOwnershipFailure.staleInspection) { try second.accepting(incomplete) }
        let surplus = LumeOwnedSetInspection(identity: owner, revision: second.revision,
                                            attemptIDs: second.attemptIDs.union([UUID()]), conclusion: .entireOwnedSetQuiescent)
        #expect(throws: LumeOwnershipFailure.staleInspection) { try second.accepting(surplus) }
        let unknown = try second.accepting(inspection(second, conclusion: .unresolved))
        #expect(unknown.phase == .quarantined(.unprovenCleanup))
        #expect(unknown.pendingAttempts == second.pendingAttempts)
    }

    @Test(arguments: 0..<5)
    func identityFieldsCannotBeSubstituted(_ field: Int) throws {
        let other = LumeOwnershipIdentity(rootDevice: field == 0 ? 2 : owner.rootDevice,
                                          rootInode: field == 1 ? 43 : owner.rootInode,
                                          operationID: field == 2 ? UUID() : owner.operationID,
                                          serviceEpoch: field == 3 ? UUID() : owner.serviceEpoch,
                                          generation: field == 4 ? UUID() : owner.generation)
        let record = try running()
        #expect(throws: LumeOwnershipFailure.staleOwner) { try record.finishing(owner: other) }
        #expect(throws: LumeOwnershipFailure.staleOwner) { try record.recording(.leaderExited, owner: other) }
        let forged = LumeOwnedSetInspection(identity: other, revision: record.revision,
                                           attemptIDs: record.attemptIDs, conclusion: .entireOwnedSetQuiescent)
        #expect(throws: LumeOwnershipFailure.staleOwner) { try record.accepting(forged) }
    }

    @Test func attemptIdentifiersCannotBeReusedOrGrowWithoutBound() throws {
        var record = LumeOwnershipRecord(reserving: owner)
        let first = UUID()
        record = try record.registeringLaunch(first, owner: owner)
        record = try record.accepting(inspection(record))
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try record.registeringLaunch(first, owner: owner) }
        for _ in 1..<LumeOwnershipRecord.maximumAttempts {
            record = try record.registeringLaunch(UUID(), owner: owner)
            record = try record.accepting(inspection(record))
        }
        #expect(throws: LumeOwnershipFailure.tooManyAttempts) { try record.registeringLaunch(UUID(), owner: owner) }
    }

    @Test func recordRoundTripsWithoutLosingUnknownOwnership() throws {
        let record = try running().recording(.terminationRefused, owner: owner)
        let decoded = try JSONDecoder().decode(LumeOwnershipRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try decoded.finishing(owner: owner) }
    }

    @Test func invalidOrFutureRecordsDoNotBecomeIdle() throws {
        let record = try running()
        let data = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["format"] = 2
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: LumeOwnershipFailure.unsupportedFormat) { try JSONDecoder().decode(LumeOwnershipRecord.self, from: future) }
        object["format"] = 1
        object["pendingAttempts"] = []
        let inconsistent = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: LumeOwnershipFailure.invalidRecord) { try JSONDecoder().decode(LumeOwnershipRecord.self, from: inconsistent) }
    }

    @Test func failuresOfferInspectionAndCancellationWithoutAutomaticRepair() {
        for error in [LumeOwnershipFailure.staleOwner, .staleInspection, .invalidRecord, .unsupportedFormat] {
            #expect(error.recoveryActions == [.inspectState, .cancel])
            #expect(!error.userMessage.isEmpty)
            #expect(error.errorDescription == error.userMessage)
        }
    }
}
