import Synchronization
import Testing
@testable import GuesthouseCore

struct RuntimeRegistrationTests {
    @Test func typedRegistrationReturnsOwnershipWithoutAnsweringOrFinishing() {
        let gate = RuntimeSessionGate()
        #expect(gate.began() == 0)
        var received: RuntimeRequest?
        let result = gate.commitRegistration(.runtimeVersion) { request in
            received = request
            return UInt64(42)
        }
        guard case .registered(let ticket) = result else { Issue.record("Registration refused"); return }
        #expect(ticket == 42)
        #expect(received == .runtimeVersion)
        #expect(gate.state.withLock { $0.inFlight } == 1)
        // Reading/reentering the gate is safe after returning the registration value.
        #expect(gate.refusal == nil)
        #expect(!gate.finished())
    }

    @Test func priorRefusalDoesNotRunRegistrationOrConsumeTheCountedReply() {
        let gate = RuntimeSessionGate()
        let first = RuntimeEvent.failed(OperationID(), .unauthorizedCaller)
        #expect(gate.began() == 0)
        gate.refuse(first)
        gate.refuse(.failed(OperationID(), .invalidRuntimeReply(.malformed)))
        var registrations = 0
        let result = gate.commitRegistration(.runtimeVersion) { _ in registrations += 1; return 42 }
        guard case .refused(let event) = result else { Issue.record("Refusal was bypassed"); return }
        #expect(event == first)
        #expect(registrations == 0)
        #expect(gate.state.withLock { $0.inFlight } == 1)
        #expect(gate.finished())
        #expect(gate.began() == nil)
    }

    @Test func registeredNilIsNotRefusalAndLaterRefusalCannotRewriteTheValue() {
        let gate = RuntimeSessionGate()
        #expect(gate.began() == 0)
        let result = gate.commitRegistration(.runtimeVersion) { _ -> Int? in nil }
        gate.refuse(.failed(OperationID(), .unauthorizedCaller))
        guard case .registered(let ticket) = result else { Issue.record("Registration rewritten"); return }
        #expect(ticket == nil)
        #expect(gate.state.withLock { $0.inFlight } == 1)
        #expect(gate.finished())
    }

    @Test func thrownTypedRegistrationUnlocksAndKeepsItsReplyObligation() {
        enum Failure: Error { case rejected }
        let gate = RuntimeSessionGate()
        #expect(gate.began() == 0)
        #expect(throws: Failure.self) {
            try gate.commitRegistration(.runtimeVersion) { _ -> Int in throw Failure.rejected }
        }
        #expect(gate.state.withLockIfAvailable { $0.inFlight } == 1)
        gate.refuse(.failed(OperationID(), .unauthorizedCaller))
        #expect(gate.finished())
    }
}
