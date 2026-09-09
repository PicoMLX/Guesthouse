import Dispatch
import Foundation
import Synchronization
import Testing
@testable import GuesthouseCore

/// Migrated retirement/order regressions from retained #68, using inert Sendable handles.
/// No native session, actor inbox, connection activation, automatic replay or signing proof.
struct RuntimeSessionRegistryTests {
    @Test func installationAndActivationAreSeparateFromReservation() throws {
        let registry = makeRegistry()
        let generation = try #require(registry.reserve())
        #expect(registry.current == nil)
        #expect(registry.reserve() == nil)
        #expect(!registry.activated(generation))
        #expect(registry.install(1, for: generation))
        #expect(!registry.install(2, for: generation))
        #expect(registry.current == nil)
        #expect(registry.activated(generation))
        #expect(registry.current?.session == 1)
        #expect(registry.current?.generation === generation)
        #expect(registry.retire(generation) == 1)
        #expect(registry.current == nil)
    }

    @Test(arguments: [false, true])
    func retirementDuringSetupCannotResurrectCandidate(installed: Bool) throws {
        let records = Records()
        let registry = makeRegistry(records)
        let old = try #require(registry.reserve())
        if installed { #expect(registry.install(1, for: old)) }
        #expect(registry.retire(old) == (installed ? 1 : nil))
        #expect(!registry.activated(old))
        #expect(!registry.install(1, for: old))
        #expect(registry.retire(old) == nil)
        #expect(records.failures.withLock { $0.count } == 1)
        let replacement = try connected(registry, handle: 2)
        #expect(replacement !== old)
        #expect(registry.current?.session == 2)
    }

    @Test func lateAcceptanceKeepsItsIDAsUnknownWithoutReachingReplacement() throws {
        let records = Records()
        let registry = makeRegistry(records)
        let old = try connected(registry)
        let acceptedID = OperationID()
        let originalFailure = RuntimeSessionFailure(cause: .protocolMismatch(service: 99), operationID: OperationID(), mayHaveMutated: true)
        #expect(registry.retire(old, failure: originalFailure) == 1)
        let replacement = try connected(registry, handle: 2)
        let late = delivered(registry, .success(.accepted(acceptedID)), from: old)
        guard case .failure(let error) = late else { Issue.record("Stale acceptance became live"); return }
        #expect(error.cause == originalFailure.cause)
        #expect(error.operationID == acceptedID)
        #expect(error.outcomeUnknown && !error.recoveryActions.contains(.retry))
        #expect(error.contextualized().operationID == acceptedID)
        // Generation-wide reports must not blame unrelated requests on the triggering ID.
        #expect(records.failures.withLock { $0 } == [RuntimeSessionFailure(cause: originalFailure.cause)])
        #expect(registry.retire(old, failure: .init(cause: .malformedResponse)) == nil)
        let current = RuntimeEvent.runtimeVersion(RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1"))
        #expect(try delivered(registry, .success(current), from: replacement).get() == current)
        registry.deliverIncoming(.completed(acceptedID), from: old)
        registry.deliverIncoming(current, from: replacement)
        #expect(records.events.withLock { $0 } == [current])
    }

    @Test(arguments: [RuntimeSessionFailure.Cause.malformedResponse, .oversizedResponse, .protocolMismatch(service: 99)])
    func ordinaryRetirementPreservesLateRepliesSpecificCauseOnlyForThatRequest(cause: RuntimeSessionFailure.Cause) throws {
        let registry = makeRegistry()
        let old = try connected(registry)
        _ = registry.retire(old)
        let current = try connected(registry, handle: 2)
        let specific = RuntimeSessionFailure(cause: cause, mayHaveMutated: true)
        #expect(delivered(registry, .failure(specific), from: old) == .failure(specific))
        // The late decoder cannot rewrite retirement cause or poison the replacement.
        #expect(delivered(registry, .success(.completed(OperationID())), from: old) == .failure(.init(cause: .connectionLost)))
        #expect(registry.current?.generation === current)
    }

    @Test func storedRetirementCauseWinsWithoutLosingPerReplyUncertainty() throws {
        let registry = makeRegistry()
        let old = try connected(registry)
        _ = registry.retire(old, failure: .init(cause: .oversizedResponse))
        let id = OperationID()
        let later = RuntimeSessionFailure(cause: .connectionLost, operationID: id, mayHaveMutated: true)
        #expect(delivered(registry, .failure(later), from: old) == .failure(
            .init(cause: .oversizedResponse, operationID: id, mayHaveMutated: true)))
    }

    @Test func deliveryAndInterruptionShareTheReservationLockWithoutTimingAssumptions() throws {
        let probe = RegistryProbe()
        let registry = RuntimeSessionRegistry<Int>(incoming: { _ in
            #expect(probe.isDeliveryLocked())
        }, interrupted: { _ in
            // A replacement reserve() uses this same lock, so it cannot overtake this enqueue.
            #expect(probe.isDeliveryLocked())
        })
        probe.registry.withLock { $0 = registry }
        defer { probe.registry.withLock { $0 = nil } }
        let generation = try connected(registry)
        let event = RuntimeEvent.completed(OperationID())
        registry.deliverReply(.success(event), from: generation) { _ in
            #expect(registry.state.withLockIfAvailable { _ in true } == nil)
        }
        registry.deliverIncoming(event, from: generation)
        #expect(registry.retire(generation) == 1)
        #expect(registry.state.withLockIfAvailable { _ in true } == true)
    }

    @Test func concurrentReservationsAndRetirementsHaveOneOwner() throws {
        let records = Records()
        let registry = makeRegistry(records)
        let reservations = Mutex<[RuntimeSessionGeneration]>([])
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if let generation = registry.reserve() { reservations.withLock { $0.append(generation) } }
        }
        #expect(reservations.withLock { $0.count } == 1)
        let generation = try #require(reservations.withLock { $0.first })
        #expect(registry.install(1, for: generation))
        #expect(registry.activated(generation))
        let cancellationOwners = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if registry.retire(generation) != nil { cancellationOwners.withLock { $0 += 1 } }
        }
        #expect(cancellationOwners.withLock { $0 } == 1)
        #expect(records.failures.withLock { $0.count } == 1)
    }

    @Test func registryDoesNotKeepRetiredGenerationHistoryAlive() throws {
        let registry = makeRegistry()
        weak var old: RuntimeSessionGeneration?
        do {
            let generation = try connected(registry)
            old = generation
            _ = registry.retire(generation)
        }
        #expect(old == nil)
    }

    private func makeRegistry(_ records: Records = Records()) -> RuntimeSessionRegistry<Int> {
        RuntimeSessionRegistry(incoming: { event in records.events.withLock { $0.append(event) } },
                               interrupted: { failure in records.failures.withLock { $0.append(failure) } })
    }
    private func connected(_ registry: RuntimeSessionRegistry<Int>, handle: Int = 1) throws -> RuntimeSessionGeneration {
        let generation = try #require(registry.reserve())
        #expect(registry.install(handle, for: generation))
        #expect(registry.activated(generation))
        return generation
    }
    private func delivered(_ registry: RuntimeSessionRegistry<Int>, _ result: Result<RuntimeEvent, RuntimeSessionFailure>,
                           from generation: RuntimeSessionGeneration) -> Result<RuntimeEvent, RuntimeSessionFailure> {
        let replies = Mutex<[Result<RuntimeEvent, RuntimeSessionFailure>]>([])
        registry.deliverReply(result, from: generation) { result in replies.withLock { $0.append(result) } }
        let delivered = replies.withLock { $0 }
        #expect(delivered.count == 1)
        return delivered.first ?? .failure(.init(cause: .connectionLost))
    }
}

private final class Records: Sendable {
    let events = Mutex<[RuntimeEvent]>([])
    let failures = Mutex<[RuntimeSessionFailure]>([])
}
private final class RegistryProbe: Sendable {
    let registry = Mutex<RuntimeSessionRegistry<Int>?>(nil)
    func isDeliveryLocked() -> Bool {
        guard let value = registry.withLock({ $0 }) else { return false }
        return value.state.withLockIfAvailable { _ in true } == nil
    }
}
