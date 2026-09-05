import Synchronization
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeSessionGateTests {
    @Test(arguments: [GuesthouseError.unauthorizedCaller, .protocolMismatch(client: 99, service: 7)])
    func refusalBeforeCommitPreventsRegistrationDespiteAnEarlierOpenSnapshot(error: GuesthouseError) {
        let gate = RuntimeSessionGate()
        let refusal = RuntimeEvent.failed(OperationID(), error)
        #expect(gate.began() == 0)
        #expect(gate.began() == 1)
        let earlierSnapshot = gate.refusal
        #expect(earlierSnapshot == nil)
        gate.refuse(refusal)

        var registrations = 0
        let reply = gate.commit(.runtimeVersion) { _ in
            registrations += 1
            return .completed(OperationID())
        }
        #expect(reply == refusal)
        #expect(registrations == 0)
        #expect(gate.state.withLock { $0.inFlight } == 2, "rejection still owes both replies")
        #expect(!gate.finished(), "the first reply must not discard the second")
        #expect(gate.finished(), "only the last reply claims cancellation")
        #expect(gate.began() == nil, "nothing is admitted once cancellation is claimed")
    }

    @Test func registrationRunsUnderTheSameLockAsRefusal() {
        let gate = RuntimeSessionGate()
        let expected = RuntimeEvent.completed(OperationID())
        #expect(gate.began() == 0)
        var lockWasHeld = false
        var registeredRequest: RuntimeRequest?
        let reply = gate.commit(.runtimeVersion) { request in
            // Unlike a scheduling sleep, this fails deterministically if commit reads a
            // snapshot, unlocks, and only then calls registration. It never blocks/reenters.
            lockWasHeld = gate.state.withLockIfAvailable { _ in true } == nil
            registeredRequest = request
            return expected
        }
        #expect(lockWasHeld)
        #expect(registeredRequest == .runtimeVersion)
        #expect(reply == expected)
        #expect(!gate.finished(), "an unrefused session stays open")
    }

    @Test func laterRefusalPreservesTheAlreadyRegisteredAnswerAndFirstRejection() {
        let gate = RuntimeSessionGate()
        let expected = RuntimeEvent.completed(OperationID())
        let first = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        #expect(gate.began() == 0)
        let reply = gate.commit(.runtimeVersion) { _ in expected }
        gate.refuse(first)
        gate.refuse(.failed(OperationID(), .protocolMismatch(client: 99, service: 7)))
        #expect(reply == expected)
        #expect(gate.refusal == first)
        #expect(gate.state.withLock { $0.inFlight } == 1)
        #expect(gate.finished())
        #expect(gate.began() == nil)
    }

    @Test func thrownRegistrationUnlocksWithoutReleasingItsReplyObligation() {
        let gate = RuntimeSessionGate()
        #expect(gate.began() == 0)
        #expect(throws: CancellationError.self) {
            try gate.commit(.runtimeVersion) { _ in throw CancellationError() }
        }
        #expect(gate.state.withLockIfAvailable { $0.inFlight } == 1)
        gate.refuse(.failed(OperationID(), .unauthorizedCaller))
        #expect(gate.finished(), "the caller still owns sending its failure then finishing")
        #expect(gate.began() == nil)
    }

    @Test func gateHasCheckedSendableConformance() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(RuntimeSessionGate.self)
    }
}
