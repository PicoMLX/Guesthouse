import GuesthouseCore
import Testing
import XPC
@testable import Guesthouse

@Suite(.timeLimit(.minutes(1))) struct NativeRuntimeEventEnvelopeTests {
    @Test(arguments: [
        RuntimeEvent.runtimeVersion(RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1")),
        .accepted(OperationID()),
        .progress(OperationID(), ProgressPhase(kind: .copying)),
        .log(nil, RedactedLine(literal: "Service launched")),
        .status(EnvironmentStatus(environmentID: EnvironmentID(), vm: .running, readiness: .ready)),
        .completed(OperationID()),
        .failed(OperationID(), .canceled),
    ])
    func wrappedRepliesReachTheDomain(event: RuntimeEvent) async throws {
        #expect(try await reply(to: RuntimeEventEnvelope(event: event)) == event)
    }

    @Test func foreignRepliesPreserveTheTypedMismatchBeforeUnknownPayloadDecoding() async throws {
        let caught = await #expect(throws: RuntimeEventEnvelope.ProtocolMismatch.self) {
            try await reply(to: UnknownEventEnvelope(protocolVersion: RuntimeProtocolVersion(99)))
        }
        let mismatch = try #require(caught)
        #expect(mismatch.service == RuntimeProtocolVersion(99))
        #expect(mismatch.error == .protocolMismatch(client: RuntimeProtocolVersion.current.rawValue, service: 99))
    }

    @Test func unknownCurrentRepliesAreMalformed() async {
        await #expect(throws: DecodingError.self) {
            try await reply(to: UnknownEventEnvelope(protocolVersion: .current))
        }
    }

    @Test func malformedCurrentRepliesAreRefused() async {
        await #expect(throws: DecodingError.self) {
            try await reply(to: MalformedEventEnvelope())
        }
    }

    @Test func unversionedRepliesAreRefused() async {
        await #expect(throws: DecodingError.self) {
            try await reply(to: RuntimeEvent.completed(OperationID()))
        }
    }

    @Test(arguments: [
        RuntimeEvent.progress(OperationID(), ProgressPhase(kind: .copying)),
        .completed(OperationID()),
    ])
    func wrappedPushesReachTheDomain(event: RuntimeEvent) async throws {
        let delivery = try await pushed(RuntimeEventEnvelope(event: event))
        #expect(delivery.event == event)
        #expect(delivery.failure == nil)
    }

    @Test func foreignPushesPreserveTheTypedMismatchBeforeUnknownPayloadDecoding() async throws {
        let delivery = try await pushed(UnknownEventEnvelope(protocolVersion: RuntimeProtocolVersion(99)))
        #expect(delivery.event == nil)
        let failure = try #require(delivery.failure)
        #expect(failure.cause == .protocolMismatch(RuntimeEventEnvelope.ProtocolMismatch(service: RuntimeProtocolVersion(99))))
    }

    @Test(arguments: [
        UnknownEventEnvelope(protocolVersion: .current),
        MalformedEventEnvelope(),
        RuntimeEvent.completed(OperationID()),
    ] as [any Encodable & Sendable])
    func malformedAndUnversionedPushesAreRefused(payload: any Encodable & Sendable) async throws {
        let delivery = try await pushed(payload)
        #expect(delivery.event == nil)
        #expect(try #require(delivery.failure).cause == .malformedResponse)
    }

    /// An anonymous endpoint exercises the real XPC codec and production reply decoder;
    /// it never names, installs, signs, or launches the embedded runtime service.
    private func reply(to payload: any Encodable & Sendable) async throws -> RuntimeEvent {
        let listener = XPCListener { request in
            request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
                #expect(throws: Never.self) {
                    let envelope = try message.decode(as: RuntimeRequestEnvelope.self)
                    #expect(envelope.protocolVersion == .current)
                    #expect(envelope.request == .runtimeVersion)
                }
                return payload
            }
        }
        defer { listener.cancel() }
        let session = try XPCSession(endpoint: listener.endpoint)
        defer { session.cancel(reason: "test completed") }
        let (stream, continuation) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        try session.sendEnvelope(RuntimeRequestEnvelope(request: .runtimeVersion)) { result in
            continuation.yield(with: result)
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    /// The push handler receives a real one-way XPC message, not a JSON stand-in.
    private func pushed(_ payload: any Encodable & Sendable) async throws -> PushDelivery {
        let (stream, continuation) = AsyncStream<PushDelivery>.makeStream()
        let listener = XPCListener { request in
            request.accept { (message: XPCReceivedMessage) -> (any Encodable)? in
                XPCRuntimeTransport.handleIncoming(
                    message,
                    incoming: { continuation.yield(PushDelivery(event: $0, failure: nil)) },
                    dropped: { _, failure in continuation.yield(PushDelivery(event: nil, failure: failure)) }
                )
                continuation.finish()
                return nil
            }
        }
        defer { listener.cancel() }
        let session = try XPCSession(endpoint: listener.endpoint)
        defer { session.cancel(reason: "test completed") }
        try session.send(payload)
        var deliveries: [PushDelivery] = []
        for await delivery in stream { deliveries.append(delivery) }
        try #require(deliveries.count == 1, "Exactly one incoming-or-dropped callback")
        return try #require(deliveries.first)
    }
}

private struct PushDelivery: Sendable {
    let event: RuntimeEvent?
    let failure: RuntimeSessionFailure?
}

private struct UnknownEventEnvelope: Encodable, Sendable {
    let protocolVersion: RuntimeProtocolVersion
    let event: [String: [String: String]] = ["futureEvent": [:]]
}

private struct MalformedEventEnvelope: Encodable, Sendable {
    let protocolVersion = RuntimeProtocolVersion.current
    let event = 73
}
