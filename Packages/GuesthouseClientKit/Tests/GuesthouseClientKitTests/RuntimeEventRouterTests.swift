import GuesthouseCore
import Testing
@testable import GuesthouseClientKit

@Suite(.timeLimit(.minutes(1))) struct RuntimeEventRouterTests {
    static let environment = EnvironmentID(), id = OperationID()
    static let info = RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1")
    static let traffic: [RuntimeEvent] = [
        .progress(id, .init(kind: .copying)),
        .diagnostic(.init(operation: .startEnvironment, outcome: .started, operationID: id.uuid)),
        .status(.init(environmentID: environment, vm: .running, readiness: .checking, inFlightOperation: id)),
    ]

    @Test(arguments: traffic, [RuntimeEvent.completed(id), .failed(id, .runtimeMissing)])
    func earlyFloodPreservesAcceptanceAndTerminal(traffic: RuntimeEvent, terminal: RuntimeEvent) async throws {
        var router = RuntimeEventRouter()
        let fixture = try start(&router)
        for _ in 0..<10_000 { #expect(router.incoming(traffic).isEmpty) }
        #expect(router.incoming(terminal).isEmpty)
        #expect(router.incoming(.completed(Self.id)).isEmpty)
        #expect(router.pendingIDCount == 1)
        #expect(router.reply(.success(.accepted(Self.id)), to: fixture.key).isEmpty)
        let values = try await collectRouting(fixture.stream)
        #expect(values == [.accepted(Self.id)] + Array(repeating: traffic, count: 15) + [terminal])
        let next = try start(&router)
        for _ in 0..<100 { #expect(router.incoming(traffic).isEmpty) }
        #expect(router.pendingIDCount == 0) // Retired ID stays retired while another reply is pending.
        #expect(router.rejected(next.key, error: .canceled).isEmpty)
        #expect(router.requestCount == 0)
    }

    @Test func snapshotsAndDiagnosticsStayWithTheirEnvironment() async throws {
        var router = RuntimeEventRouter()
        let otherEnvironment = EnvironmentID(), otherID = OperationID()
        let a = try start(&router), b = try start(&router, request: .startEnvironment(otherEnvironment, .init()))
        _ = router.reply(.success(.accepted(Self.id)), to: a.key)
        _ = router.reply(.success(.accepted(otherID)), to: b.key)
        let wrong: [RuntimeEvent] = [
            .status(.init(environmentID: otherEnvironment, vm: .running, readiness: .checking, inFlightOperation: Self.id)),
            .diagnostic(.init(operation: .startEnvironment, outcome: .started, operationID: Self.id.uuid, environmentID: otherEnvironment)),
        ]
        for event in wrong { #expect(router.incoming(event).isEmpty) }
        let statusA = RuntimeEvent.status(.init(environmentID: Self.environment, vm: .running, readiness: .checking))
        let statusB = RuntimeEvent.status(.init(environmentID: otherEnvironment, vm: .running, readiness: .checking))
        _ = router.incoming(statusA); _ = router.incoming(statusB)
        _ = router.incoming(.completed(Self.id)); _ = router.incoming(.completed(otherID))
        #expect(try await collectRouting(a.stream) == [.accepted(Self.id), statusA, .completed(Self.id)])
        #expect(try await collectRouting(b.stream) == [.accepted(otherID), statusB, .completed(otherID)])
    }

    @Test func queryRepliesAndKnownLocalRejectionsSettleWithoutCancellation() async throws {
        let cases: [(RuntimeRequest, RuntimeEvent)] = [
            (.runtimeVersion, .runtimeVersion(Self.info)),
            (.environmentStatus(Self.environment), .status(.init(environmentID: Self.environment, vm: .stopped, readiness: .checking))),
            (.cancelOperation(Self.id), .completed(OperationID())),
            (.startEnvironment(Self.environment, .init()), .failed(Self.id, .runtimeMissing)),
        ]
        var router = RuntimeEventRouter()
        for (request, event) in cases {
            let fixture = try start(&router, request: request)
            #expect(router.reply(.success(event), to: fixture.key).isEmpty)
            #expect(try await collectRouting(fixture.stream) == [event])
            #expect(router.consumerEnded(fixture.key, reason: .abandoned).isEmpty)
        }
        let unsent = try start(&router)
        #expect(router.rejected(unsent.key, error: .invalidRequest(.malformed)).isEmpty)
        await #expect(throws: GuesthouseError.invalidRequest(.malformed)) { try await collectRouting(unsent.stream) }
        #expect(router.isIdle)
    }

    @Test(arguments: [false, true])
    func unexpectedReplyRetainsIdentityAndRetires(accepted: Bool) async throws {
        var router = RuntimeEventRouter()
        let fixture = try start(&router, request: .runtimeVersion)
        let event: RuntimeEvent = accepted ? .accepted(Self.id) : .progress(Self.id, .init(kind: .copying))
        let failure = RuntimeSessionFailure(cause: .malformedResponse, operationID: Self.id)
        #expect(router.reply(.success(event), to: fixture.key) == [unknown(fixture, failure, environment: nil), .retireConnection])
        await #expect(throws: failure) { try await collectRouting(fixture.stream) }
        #expect(router.isIdle)
    }

    @Test func namedOperationsAcceptButWrongQueryShapesDoNot() async throws {
        let operations: [RuntimeRequest] = [
            .startEnvironment(Self.environment, .init()), .stopEnvironment(Self.environment, .force),
            .importXcode(Self.environment, .init(kind: .fileDescriptor(token: Self.id.uuid), displayName: "Xcode")),
        ]
        for request in operations {
            var router = RuntimeEventRouter()
            let fixture = try start(&router, request: request)
            #expect(router.reply(.success(.accepted(Self.id)), to: fixture.key).isEmpty)
            _ = router.incoming(.completed(Self.id))
            #expect(try await collectRouting(fixture.stream) == [.accepted(Self.id), .completed(Self.id)])
        }
        let cases: [(RuntimeRequest, RuntimeEvent, RuntimeSessionFailure.Cause)] = [
            (.environmentStatus(Self.environment), .status(.init(environmentID: EnvironmentID(), vm: .stopped, readiness: .checking)), .malformedResponse),
            (.runtimeVersion, .runtimeVersion(.init(serviceVersion: "1", serviceBuild: "1", protocolVersion: .init(11))), .protocolMismatch(service: 11)),
        ]
        for (request, event, cause) in cases {
            var router = RuntimeEventRouter()
            let fixture = try start(&router, request: request)
            #expect(router.reply(.success(event), to: fixture.key) == [.retireConnection])
            await #expect(throws: RuntimeSessionFailure(cause: cause)) { try await collectRouting(fixture.stream) }
        }
    }

    @Test func pendingIDOverflowFailsClosedAndKeepsTheLateOwningReply() async throws {
        var router = RuntimeEventRouter()
        let fixture = try start(&router)
        for _ in 0..<RuntimeEventRouter.pendingIDLimit { _ = router.incoming(.completed(OperationID())) }
        #expect(router.pendingIDCount == RuntimeEventRouter.pendingIDLimit)
        let failure = RuntimeSessionFailure(cause: .oversizedResponse, mayHaveMutated: true)
        #expect(router.incoming(.completed(Self.id)) == [.retireConnection, unknown(fixture, failure)])
        #expect(router.pendingIDCount == 0)
        #expect(router.requestCount == 1)
        let refused = Fixture()
        #expect(router.register(refused.key, request: .runtimeVersion, producer: refused.producer) == .retiring)
        await #expect(throws: failure) { try await collectRouting(fixture.stream) }
        #expect(router.consumerEnded(fixture.key, reason: .finished).isEmpty)
        // Even after the consumer observed failure, reconciliation learns the late identity.
        #expect(router.reply(.success(.accepted(Self.id)), to: fixture.key) == [
            unknown(fixture, failure.contextualized(operationID: Self.id)),
        ])
        #expect(router.isIdle)
        #expect(router.incoming(.completed(OperationID())).isEmpty)
    }

    @Test func interruptionDoesNotEraseAwaitingRepliesFromTheReplacement() async throws {
        var router = RuntimeEventRouter()
        let old = try start(&router), pending = try start(&router)
        _ = router.reply(.success(.accepted(Self.id)), to: old.key)
        let newID = OperationID()
        _ = router.incoming(.progress(newID, .init(kind: .copying)))
        let failure = RuntimeSessionFailure(cause: .protocolMismatch(service: 11), operationID: Self.id, mayHaveMutated: true)
        #expect(router.interrupted(.init(cause: .protocolMismatch(service: 11), operationID: OperationID())) == [unknown(old, failure)])
        #expect(router.pendingIDCount == 0)
        #expect(router.requestCount == 1)
        await #expect(throws: failure) { try await collectRouting(old.stream) }
        // A stale native acceptance must arrive as failure; this success belongs to the new generation.
        #expect(router.reply(.success(.accepted(newID)), to: pending.key).isEmpty)
        _ = router.incoming(.completed(newID))
        #expect(try await collectRouting(pending.stream) == [.accepted(newID), .completed(newID)])
    }

    @Test func retiredOwningReplyStillReportsUnknownIdentity() async throws {
        var router = RuntimeEventRouter()
        let fixture = try start(&router)
        #expect(router.interrupted(.init(cause: .connectionLost)).isEmpty)
        let failure = RuntimeSessionFailure(cause: .protocolMismatch(service: 11), operationID: Self.id, mayHaveMutated: true)
        #expect(router.reply(.failure(failure), to: fixture.key) == [unknown(fixture, failure)])
        await #expect(throws: failure) { try await collectRouting(fixture.stream) }
        #expect(router.isIdle)
    }

    @Test(arguments: [false, true])
    func abandonedConsumersCancelOnceIncludingLateAcceptance(beforeAcceptance: Bool) throws {
        var router = RuntimeEventRouter()
        let fixture = try start(&router)
        if !beforeAcceptance { _ = router.reply(.success(.accepted(Self.id)), to: fixture.key) }
        let first = router.consumerEnded(fixture.key, reason: .abandoned)
        #expect(first == (beforeAcceptance ? [] : [.cancel(Self.id)]))
        if beforeAcceptance {
            #expect(router.requestCount == 1)
            #expect(router.reply(.success(.accepted(Self.id)), to: fixture.key) == [.cancel(Self.id)])
        }
        #expect(router.consumerEnded(fixture.key, reason: .abandoned).isEmpty)
        #expect(router.isIdle)
        #expect(router.retiredCount == 1)
    }

    @Test(arguments: [false, true])
    func duplicateAcceptanceNeverStealsAnExistingConsumer(sameKey: Bool) async throws {
        var router = RuntimeEventRouter()
        let a = try start(&router), b = try start(&router)
        _ = router.reply(.success(.accepted(Self.id)), to: a.key)
        let effects = router.reply(.success(.accepted(Self.id)), to: sameKey ? a.key : b.key)
        #expect(effects.filter { $0 == .retireConnection }.count == 1)
        let failure = RuntimeSessionFailure(cause: .malformedResponse, operationID: Self.id, mayHaveMutated: true)
        await #expect(throws: failure) { try await collectRouting(a.stream) }
        #expect(router.incoming(.completed(Self.id)).isEmpty)
    }

    @Test func duplicateAcceptanceRetainsBothIDsWithTheOriginalRequestContext() async throws {
        var router = RuntimeEventRouter()
        let fixture = try start(&router), secondID = OperationID()
        _ = router.reply(.success(.accepted(Self.id)), to: fixture.key)
        let first = RuntimeSessionFailure(cause: .malformedResponse, operationID: Self.id, mayHaveMutated: true)
        let second = RuntimeSessionFailure(cause: .malformedResponse, operationID: secondID, mayHaveMutated: true)
        #expect(router.reply(.success(.accepted(secondID)), to: fixture.key) == [
            unknown(fixture, second), .retireConnection, unknown(fixture, first),
        ])
        await #expect(throws: first) { try await collectRouting(fixture.stream) }
        #expect(router.isIdle)
    }

    @Test func preAcceptanceFaultRetainsDistinctEnvironmentsAndCancellationTarget() async throws {
        var router = RuntimeEventRouter()
        let other = EnvironmentID()
        let a = try start(&router), b = try start(&router, request: .stopEnvironment(other, .force))
        let cancel = try start(&router, request: .cancelOperation(Self.id))
        let failure = RuntimeSessionFailure(cause: .malformedResponse, mayHaveMutated: true)
        let effects = router.incoming(.runtimeVersion(Self.info))
        #expect(effects.count == 4)
        #expect(effects.contains(.retireConnection))
        #expect(effects.contains(unknown(a, failure)))
        #expect(effects.contains(unknown(b, failure, environment: other)))
        #expect(effects.contains(unknown(cancel, failure, environment: nil, cancellationTarget: Self.id)))
        for fixture in [a, b, cancel] {
            await #expect(throws: failure) { try await collectRouting(fixture.stream) }
        }
        #expect(router.requestCount == 3) // Owning replies can still supply late IDs.
    }

    @Test func requestAndLifetimeBudgetsAreBounded() throws {
        var router = RuntimeEventRouter()
        let outstanding = try (0..<RuntimeEventRouter.requestLimit).map { _ in try start(&router) }
        let extra = Fixture()
        #expect(router.register(extra.key, request: .runtimeVersion, producer: extra.producer) == .full)
        for fixture in outstanding { _ = router.rejected(fixture.key, error: .canceled) }
        for _ in RuntimeEventRouter.requestLimit..<RuntimeEventRouter.lifetimeLimit {
            let fixture = try start(&router)
            let id = OperationID()
            _ = router.reply(.success(.accepted(id)), to: fixture.key)
            _ = router.incoming(.completed(id))
        }
        #expect(router.isIdle)
        #expect(router.retiredCount == RuntimeEventRouter.lifetimeLimit - RuntimeEventRouter.requestLimit)
        #expect(router.register(extra.key, request: .runtimeVersion, producer: extra.producer) == .rotationRequired)
        #expect(router.interrupted(.init(cause: .connectionLost)).isEmpty)
        #expect(router.retiredCount == 0)
        #expect(router.register(extra.key, request: .runtimeVersion, producer: extra.producer) == .admitted)
    }
}

private struct Fixture {
    let key = RuntimeRequestKey()
    let producer: RuntimeEventStream
    let stream: AsyncThrowingStream<RuntimeEvent, any Error>
    init(mutating: Bool = false) {
        (producer, stream) = RuntimeEventStream.make(mayHaveMutated: mutating) { _ in }
    }
}
private func start(_ router: inout RuntimeEventRouter,
                   request: RuntimeRequest = .startEnvironment(RuntimeEventRouterTests.environment, .init())) throws -> Fixture {
    let mutating: Bool
    switch request { case .runtimeVersion, .environmentStatus: mutating = false; default: mutating = true }
    let fixture = Fixture(mutating: mutating)
    try #require(router.register(fixture.key, request: request, producer: fixture.producer) == .admitted)
    return fixture
}
private func collectRouting(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
    var values: [RuntimeEvent] = []
    for try await value in stream { values.append(value) }
    return values
}
private func unknown(_ fixture: Fixture, _ failure: RuntimeSessionFailure,
                     environment: EnvironmentID? = RuntimeEventRouterTests.environment,
                     cancellationTarget: OperationID? = nil) -> RuntimeEventRouter.Effect {
    .unknownOutcome(.init(key: fixture.key, environmentID: environment, cancellationTarget: cancellationTarget, failure: failure))
}
