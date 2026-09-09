import Dispatch
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseClientKit

@Suite struct RuntimeTransportTests {
    @Test func invalidOutgoingOptionsNeverConnect() {
        let fixture = TransportFixture()
        defer { fixture.releaseCallbacks() }
        #expect(throws: GuesthouseError.invalidRequest(.malformed)) {
            try fixture.client().send(.init(request: .startEnvironment(EnvironmentID(), .init(ipWait: .seconds(-1))))) { _ in }
        }
        #expect(fixture.sessions.withLock { $0.isEmpty })
    }

    @Test(arguments: [Mode.connectFails, .activationFails, .retireBeforeInstall, .retireDuringActivation, .contractFailureDuringActivation, .replyFails])
    func failuresRetireOnceAndOnlyTheNextRequestReconnects(mode: Mode) throws {
        let fixture = TransportFixture(mode)
        defer { fixture.releaseCallbacks() }
        let client = fixture.client()
        for _ in 0..<2 {
            if mode == .replyFails { try client.queryRuntimeVersion { result in fixture.replies.withLock { $0.append(result) } } }
            else {
                let cause: RuntimeSessionFailure.Cause = mode == .contractFailureDuringActivation ? .malformedResponse : .connectionLost
                #expect(throws: RuntimeSessionFailure(cause: cause)) { try client.queryRuntimeVersion { _ in } }
            }
        }
        let sessions = fixture.sessions.withLock { $0 }
        #expect(sessions.count == 2)
        #expect(fixture.interruptions.withLock { $0.count } == 2)
        let results = fixture.replies.withLock { $0 }
        #expect(results.count == (mode == .replyFails ? 2 : 0))
        for result in results { #expect(throws: RuntimeSessionFailure(cause: .malformedResponse)) { try result.get() } }
        for session in sessions {
            #expect(session.cancellations.withLock { $0 } == (mode == .connectFails ? 0 : 1))
            #expect(session.sends.withLock { $0.count } == (mode == .replyFails ? 1 : 0))
        }
    }

    @Test func lateAcceptanceKeepsItsIdentityWithoutContaminatingReplacement() throws {
        let fixture = TransportFixture(.held)
        defer { fixture.releaseCallbacks() }
        let client = fixture.client()
        try client.send(.init(request: .startEnvironment(EnvironmentID(), .init()))) { result in
            fixture.replies.withLock { $0.append(result) }
        }
        let old = try #require(fixture.sessions.withLock { $0.first })
        old.incoming(.failure(.init(cause: .oversizedResponse)))
        try client.queryRuntimeVersion { result in fixture.replies.withLock { $0.append(result) } }
        let replacement = try #require(fixture.sessions.withLock { $0.last })
        let id = OperationID()
        let lateReply = try #require(old.sends.withLock { $0.first })
        lateReply(.success(.accepted(id)))
        old.incoming(.success(.completed(id)))
        old.dropped()
        let liveReply = try #require(replacement.sends.withLock { $0.first })
        liveReply(.success(versionEvent))
        let results = fixture.replies.withLock { $0 }
        try #require(results.count == 2)
        #expect(throws: RuntimeSessionFailure(cause: .oversizedResponse, operationID: id, mayHaveMutated: true)) { try results[0].get() }
        #expect(try results[1].get() == versionEvent)
        #expect(fixture.incoming.withLock { $0.isEmpty })
        #expect(fixture.interruptions.withLock { $0 } == [.init(cause: .oversizedResponse)])
        #expect(replacement.cancellations.withLock { $0 } == 0)
    }

    @Test func simultaneousQueriesShareOneActivatedConnection() throws {
        let fixture = TransportFixture()
        defer { fixture.releaseCallbacks() }
        let client = fixture.client()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            #expect(throws: Never.self) {
                try client.queryRuntimeVersion { result in fixture.replies.withLock { $0.append(result) } }
            }
        }
        let sessions = fixture.sessions.withLock { $0 }
        try #require(sessions.count == 1)
        #expect(sessions[0].activations.withLock { $0 } == 1)
        #expect(sessions[0].sends.withLock { $0.count } == 32)
        #expect(fixture.replies.withLock { $0.count } == 32)
    }

    @Test func releasingClientCancelsTheConnectionDespitePendingReply() throws {
        let fixture = TransportFixture(.held)
        defer { fixture.releaseCallbacks() }
        var client: XPCRuntimeTransport? = fixture.client()
        weak let weakClient = client
        try client?.queryRuntimeVersion { _ in }
        client = nil
        #expect(weakClient == nil)
        #expect(try #require(fixture.sessions.withLock { $0.first }).cancellations.withLock { $0 } == 1)
        #expect(fixture.interruptions.withLock { $0.count } == 1)
    }
}

private let versionEvent = RuntimeEvent.runtimeVersion(RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1"))
enum Mode: Sendable { case success, connectFails, activationFails, retireBeforeInstall, retireDuringActivation, contractFailureDuringActivation, replyFails, held }
private final class TransportFixture: Sendable {
    let mode: Mode
    let sessions = Mutex<[TestSession]>([])
    let interruptions = Mutex<[RuntimeSessionFailure]>([])
    let incoming = Mutex<[RuntimeEvent]>([])
    let replies = Mutex<[Result<RuntimeEvent, RuntimeSessionFailure>]>([])
    init(_ mode: Mode = .success) { self.mode = mode }
    func releaseCallbacks() {
        for session in sessions.withLock({ $0 }) { session.sends.withLock { $0.removeAll() } }
    }
    func client() -> XPCRuntimeTransport {
        XPCRuntimeTransport(
            incoming: { event in self.incoming.withLock { $0.append(event) } },
            interrupted: { failure in self.interruptions.withLock { $0.append(failure) } },
            connect: { incoming, dropped in
                let session = TestSession(mode: self.mode, incoming: incoming, dropped: dropped)
                self.sessions.withLock { $0.append(session) }
                if self.mode == .connectFails { throw CocoaError(.fileReadCorruptFile) }
                if self.mode == .retireBeforeInstall { dropped() }
                return session
            }
        )
    }
}

private final class TestSession: RuntimeClientSession {
    let mode: Mode
    let incoming: @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void
    let dropped: @Sendable () -> Void
    let activations = Mutex(0), cancellations = Mutex(0)
    let sends = Mutex<[@Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void]>([])
    init(mode: Mode, incoming: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void,
         dropped: @escaping @Sendable () -> Void) {
        self.mode = mode; self.incoming = incoming; self.dropped = dropped
    }
    func activate() throws {
        activations.withLock { $0 += 1 }
        if mode == .activationFails { throw CocoaError(.fileReadCorruptFile) }
        if mode == .retireDuringActivation { dropped() }
        if mode == .contractFailureDuringActivation { incoming(.failure(.init(cause: .malformedResponse))) }
    }
    func cancel() { cancellations.withLock { $0 += 1 }; dropped() } // Synchronous reentry must not deadlock.
    func send(_ payload: Data, reply: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void) {
        sends.withLock { $0.append(reply) }
        if mode == .held { return }
        reply(mode == .replyFails ? .failure(.init(cause: .malformedResponse)) : .success(versionEvent))
    }
}
