import Dispatch
import Foundation
import Synchronization
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeSessionGateTests {
    @Test func concurrentRepliesClaimExactlyOneClose() {
        let gate = RuntimeSessionGate()
        let closes = Mutex(0)
        for index in 0..<32 { #expect(gate.began() == index) }
        gate.refuse(.failed(OperationID(), .unauthorizedCaller))
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if gate.finished() { closes.withLock { $0 += 1 } }
        }
        #expect(closes.withLock { $0 } == 1)
        #expect(gate.state.withLock { $0.inFlight } == 0)
        #expect(gate.began() == nil)
    }

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
        let lockWasHeld = Mutex<Bool?>(nil)
        let observed = DispatchSemaphore(value: 0)
        var registeredRequest: RuntimeRequest?
        let reply = gate.commit(.runtimeVersion) { request in
            // A distinct native thread avoids recursively trying the nonrecursive mutex.
            // This synchronous test holds the callback open only until the nonblocking probe
            // completes (bounded wait, no scheduling sleeps or async-executor blocking).
            Thread.detachNewThread {
                let unavailable = gate.state.withLockIfAvailable { _ in true } == nil
                lockWasHeld.withLock { $0 = unavailable }
                observed.signal()
            }
            #expect(observed.wait(timeout: .now() + 5) == .success)
            registeredRequest = request
            return expected
        }
        #expect(lockWasHeld.withLock { $0 } == true)
        #expect(registeredRequest == .runtimeVersion)
        #expect(reply == expected)
        #expect(!gate.finished(), "an unrefused session stays open")
    }

    @Test func trafficAfterRefusalCannotExtendTheDrain() {
        let gate = RuntimeSessionGate()
        let first = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        #expect(gate.began() == 0)
        #expect(gate.began() == 1)
        gate.refuse(first)
        let unexpectedAdmissions = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if gate.began() != nil { unexpectedAdmissions.withLock { $0 += 1 } }
        }
        #expect(unexpectedAdmissions.withLock { $0 } == 0)
        #expect(gate.state.withLock { $0.inFlight } == 2)
        #expect(!gate.state.withLock { $0.isClosing }, "already counted replies must be handed over")
        var registrations = 0
        #expect(gate.commit(.runtimeVersion) { _ in registrations += 1; return .completed(OperationID()) } == first)
        #expect(registrations == 0)
        #expect(!gate.finished())
        #expect(gate.began() == nil, "the remaining reply cannot be kept alive by new traffic")
        #expect(gate.finished())
        #expect(gate.state.withLock { $0.inFlight } == 0)
        #expect(gate.state.withLock { $0.isClosing })
        #expect(gate.began() == nil)
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
