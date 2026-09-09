import Foundation
import GuesthouseCore
import Synchronization
import Testing
import XPC
@testable import GuesthouseClientKit

/// Anonymous native I/O, never a signed-app identity, embedding, provider or hardware proof.
@Suite(.timeLimit(.minutes(1))) struct NativeRuntimeSessionTests {
    enum Shape: Sendable, CaseIterable {
        case current, exactBoundary, oversized, foreignOuter, contradictoryInner, unknownEvent, bareEvent, wrongHeader, wrongPayload, extraKey
    }
    @Test(arguments: Shape.allCases, [false, true])
    func boundedNativeRepliesAndPushes(shape: Shape, push: Bool) async throws {
        let result = try await exchange(shape, push: push)
        switch shape {
        case .current, .exactBoundary: #expect(try result.get() == event)
        case .oversized: #expect(throws: RuntimeSessionFailure(cause: .oversizedResponse)) { try result.get() }
        case .foreignOuter: #expect(throws: RuntimeSessionFailure(cause: .protocolMismatch(service: 99))) { try result.get() }
        default: #expect(throws: RuntimeSessionFailure(cause: .malformedResponse)) { try result.get() }
        }
    }

    @Test(arguments: [false, true])
    func cancellationSafelyDisposesOfInactiveOrActiveSessions(active: Bool) throws {
        let listener = XPCListener { request in request.reject(reason: "Test cleanup only") }
        defer { listener.cancel() }
        let session = NativeRuntimeSession(try XPCSession(endpoint: listener.endpoint, options: .inactive))
        if active { try session.activate() }
        session.cancel(); session.cancel()
        #expect(throws: RuntimeSessionFailure(cause: .connectionLost)) { try session.activate() }
        let received = Results()
        session.send(Data([1])) { result in received.values.withLock { $0.append(result) } }
        let results = received.values.withLock { $0 }
        try #require(results.count == 1)
        #expect(throws: RuntimeSessionFailure(cause: .connectionLost)) { try results[0].get() }
    }

    @Test func releasingAnUnusedNativeCandidateDoesNotViolateXPCLifecycle() throws {
        let listener = XPCListener { request in request.reject(reason: "Test cleanup only") }
        defer { listener.cancel() }
        var session: NativeRuntimeSession? = NativeRuntimeSession(try XPCSession(endpoint: listener.endpoint, options: .inactive))
        weak let released = session
        session = nil
        #expect(released == nil)
    }

    private func exchange(_ shape: Shape, push: Bool) async throws -> Result<RuntimeEvent, RuntimeSessionFailure> {
        let delivery = AsyncStream<Result<RuntimeEvent, RuntimeSessionFailure>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let holder = Server()
        let listener = XPCListener { request in
            let (decision, server) = request.accept(incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                do {
                    let bytes = try RawRuntimeFrame.payload(message, expectedVersion: epoch)
                    #expect(try RequestValidator.decode(bytes).request == .runtimeVersion)
                    let context = try #require(RawRuntimeReplyContext(receivedMessage: message))
                    let reply = try #require(try context.takeReply(payload: RuntimeEventEnvelope(event: event).encoded(), protocolVersion: epoch))
                    let peer = try #require(holder.session.withLock { $0 })
                    if push { try peer.send(message: shaped(shape, frame: XPCDictionary())) }
                    try peer.send(message: push ? reply : shaped(shape, frame: reply))
                    return nil // Context was consumed explicitly; never request a second implicit reply.
                } catch {
                    Issue.record("Native response fixture failed")
                    delivery.continuation.yield(.failure(.init(cause: .connectionLost)))
                    delivery.continuation.finish()
                    return nil
                }
            })
            holder.session.withLock { $0 = server }
            return decision
        }
        let client = XPCRuntimeTransport(
            incoming: { delivery.continuation.yield(.success($0)); delivery.continuation.finish() },
            interrupted: { if push { delivery.continuation.yield(.failure($0)); delivery.continuation.finish() } },
            connect: { incoming, dropped in
                NativeRuntimeSession(try XPCSession(
                    endpoint: listener.endpoint, options: .inactive,
                    incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                        incoming(NativeRuntimeSession.decode(message)); return nil
                    }, cancellationHandler: { _ in dropped() }
                ))
            }
        )
        defer {
            withExtendedLifetime(client) {}
            holder.session.withLock { $0 }?.cancel(reason: "Native response fixture finished")
            listener.cancel()
        }
        try client.queryRuntimeVersion { result in
            if !push { delivery.continuation.yield(result); delivery.continuation.finish() }
        }
        var iterator = delivery.stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }
}

private let epoch = Int64(RuntimeProtocolVersion.current.rawValue)
private let event = RuntimeEvent.runtimeVersion(RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1"))
private final class Server: Sendable { let session = Mutex<XPCSession?>(nil) }
private final class Results: Sendable { let values = Mutex<[Result<RuntimeEvent, RuntimeSessionFailure>]>([]) }

private func shaped(_ shape: NativeRuntimeSessionTests.Shape, frame: XPCDictionary) throws -> XPCDictionary {
    var frame = frame
    var payload = try RuntimeEventEnvelope(event: event).encoded()
    if shape == .exactBoundary { payload.append(Data(repeating: 32, count: RawRuntimeFrame.maximumPayloadBytes - payload.count)) }
    if shape == .oversized { payload = Data(repeating: 32, count: RawRuntimeFrame.maximumPayloadBytes + 1) }
    if shape == .foreignOuter || shape == .unknownEvent { payload = Data("{\"protocolVersion\":\(epoch),\"event\":{\"unknown\":{}}}".utf8) }
    if shape == .contradictoryInner { payload = Data("{\"protocolVersion\":99,\"event\":{}}".utf8) }
    if shape == .bareEvent { payload = try JSONEncoder().encode(event) }
    frame["protocolVersion"] = shape == .foreignOuter ? Int64(99) : epoch
    frame["payload"] = payload.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
    if shape == .wrongHeader { frame["protocolVersion"] = "private-fixture-marker" }
    if shape == .wrongPayload { frame["payload"] = "private-fixture-marker" }
    if shape == .extraKey { frame["private-fixture-marker"] = true }
    return frame
}
