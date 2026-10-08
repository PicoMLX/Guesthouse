import Dispatch
import Foundation
import GuesthouseCore
import Synchronization
import Testing
import XPC
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct NativeRuntimeSessionRegistrationTests {
    @Test func publicRegistrationRefusesTheActualUnsignedPeer() async throws {
        let progress = NativeXPCFixtureProgress()
        let listener = XPCListener(targetQueue: DispatchQueue(label: "public-binding.listener.\(UUID())")) { request in
            NativeRuntimeRequestHandler.accept(request, version: RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1"),
                                               diagnostic: { _ in })
        }
        let client = try XPCSession(endpoint: listener.endpoint,
                                    targetQueue: DispatchQueue(label: "public-binding.client.\(UUID())"))
        defer { client.cancel(reason: "public registration fixture completed"); listener.cancel() }
        let bytes = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .runtimeVersion))
        let message = try RawRuntimeFrame.encode(bytes, protocolVersion: Int64(RuntimeProtocolVersion.current.rawValue))
        let (stream, reply) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        client.send(message: message) { result in
            do {
                let bytes = try RawRuntimeFrame.payload(result.get(), expectedVersion: Int64(RuntimeProtocolVersion.current.rawValue))
                reply.yield(try RuntimeEventEnvelope.decode(bytes).event); reply.finish()
            } catch { reply.finish(throwing: NativeXPCFixtureFailure.streamEnded) }
        }
        guard case .failed(_, .unauthorizedCaller) = try await NativeXPCFixtureStream(stream: stream, progress: progress).next() else {
            Issue.record("The unsigned fixture passed production authentication"); return
        }
        // Anonymous native delivery is negative signing evidence only; it is not a
        // positive signed-GUI activation, streaming, VM or provider proof.
    }

    @Test func cancellationReleasesTheBoundHandlerAfterForwardingOnce() async throws {
        let progress = NativeXPCFixtureProgress()
        let accepted = Mutex<XPCSession?>(nil)
        let cancellations = Counter()
        let (stream, released) = AsyncThrowingStream<Bool, any Error>.makeStream()
        let listenerQueue = DispatchQueue(label: "native-binding.listener.\(UUID())")
        let clientQueue = DispatchQueue(label: "native-binding.client.\(UUID())")
        progress.observe(listenerQueue, bit: 1); progress.observe(clientQueue, bit: 2)
        let listener = XPCListener(targetQueue: listenerQueue) { request in
            acceptNativeRuntimeSession(request) { session in
                accepted.withLock { $0 = session }
                return Handler(session: session, cancellations: cancellations,
                    owner: Owner(released: released, cancellations: cancellations))
            }
        }
        let client = try XPCSession(endpoint: listener.endpoint, targetQueue: clientQueue)
        defer {
            client.cancel(reason: "native binding fixture completed")
            accepted.withLock { $0 }?.cancel(reason: "native binding fixture completed")
            listener.cancel(); released.finish()
        }
        let (replyStream, reply) = AsyncThrowingStream<Bool, any Error>.makeStream()
        client.send(message: XPCDictionary()) { result in
            switch result {
            case .success(let frame):
                do { reply.yield(try RawRuntimeFrame.payload(frame,
                    expectedVersion: Int64(RuntimeProtocolVersion.current.rawValue)) == Data([1])); reply.finish() }
                catch { reply.finish(throwing: error) }
            case .failure: reply.finish(throwing: NativeXPCFixtureFailure.streamEnded)
            }
        }
        #expect(try await NativeXPCFixtureStream(stream: replyStream, progress: progress).next())
        // No test retains the handler. Retaining the actual accepted session after cancel
        // must not retain its bound owner, and cleanup observes cancellation before release.
        accepted.withLock { $0 }?.cancel(reason: "native binding cancellation")
        #expect(try await NativeXPCFixtureStream(stream: stream, progress: progress).next())
        #expect(cancellations.value.withLock { $0 } == 1)
    }
}

private struct Handler: XPCPeerHandler {
    let session: XPCSession
    let cancellations: Counter
    let owner: Owner
    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        guard let context = RawRuntimeReplyContext(receivedMessage: message),
              let reply = try? context.takeReply(payload: Data([1]),
                protocolVersion: Int64(RuntimeProtocolVersion.current.rawValue)) else { return nil }
        try? session.send(message: reply)
        return nil
    }
    func handleCancellation(error: XPCRichError) { cancellations.value.withLock { $0 += 1 } }
}

private final class Owner: Sendable {
    let released: AsyncThrowingStream<Bool, any Error>.Continuation
    let cancellations: Counter
    init(released: AsyncThrowingStream<Bool, any Error>.Continuation, cancellations: Counter) {
        self.released = released; self.cancellations = cancellations
    }
    deinit { released.yield(cancellations.value.withLock { $0 } == 1); released.finish() }
}

private final class Counter: Sendable { let value = Mutex(0) }
