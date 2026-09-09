import Dispatch
import Foundation
import GuesthouseCore
import GuesthouseRuntimeAuthentication
import GuesthouseRuntimeKit
import Synchronization
import Testing
import XPC

@Suite(.timeLimit(.minutes(1))) struct RuntimeCallerAuthenticationTests {
    @Test func nullWrongTypeAndUnreceivedDictionariesAreRefused() {
        #expect(!GHRMessageSenderIsGuesthouse(nil))
        #expect(!GHRMessageSenderIsGuesthouse(xpc_int64_create(1)))
        #expect(!RuntimeCallerAuthentication.allows(XPCDictionary()))
        #expect(GHRGuesthouseSigningIdentifier == "com.starlingprotocol.Guesthouse")
    }

    @Test func concurrentChecksShareOnlyAnImmutableRequirement() {
        let allowed = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if RuntimeCallerAuthentication.allows(XPCDictionary()) {
                allowed.withLock { $0 += 1 }
            }
        }
        #expect(allowed.withLock { $0 } == 0)
    }

    // Standalone package test runners are not the signed Guesthouse GUI. Rejection may
    // mean requirement creation failed OR the sender did not match; this is not positive
    // signed-app proof. No fixture injects an authenticated decision or executes an operation.
    @Test(arguments: [false, true], [false, true])
    func nonGuesthouseMessagesAreRefused(replyBearing: Bool, spoofedFields: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let message = Self.message(spoofedFields: spoofedFields)
        if replyBearing {
            let reply = fixture.request(message)
            let observation = try await next(fixture.observations)
            #expect(!observation.allowed)
            #expect(observation.expectsReply)
            #expect(try await next(reply) == Data([0]))
        } else {
            try fixture.client.send(message: message)
            let observation = try await next(fixture.observations)
            #expect(!observation.allowed)
            #expect(!observation.expectsReply)
        }
    }

    @Test func checkerRunsForBothOneWayAndFollowingReplyBearingMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        try fixture.client.send(message: Self.message(spoofedFields: true))
        let first = try await next(fixture.observations)
        let reply = fixture.request(Self.message(spoofedFields: false))
        let second = try await next(fixture.observations)
        #expect(!first.allowed && !first.expectsReply)
        #expect(!second.allowed && second.expectsReply)
        #expect(try await next(reply) == Data([0]))
    }

    private static func message(spoofedFields: Bool) -> XPCDictionary {
        var message = XPCDictionary()
        if spoofedFields {
            message["signingIdentifier"] = GHRGuesthouseSigningIdentifier
            message["teamIdentifier"] = "claimed-team"
            message["authorized"] = true
            message["pid"] = Int64(1)
            message["payload"] = "not an authorization credential"
        }
        return message
    }
}

private struct Observation: Sendable {
    let allowed: Bool
    let expectsReply: Bool
}

private final class AcceptedSession: Sendable {
    let value = Mutex<XPCSession?>(nil)
}

private final class Fixture: Sendable {
    let listener: XPCListener
    let client: XPCSession
    let observations: AsyncThrowingStream<Observation, any Error>
    private let accepted: AcceptedSession

    init() throws {
        let (stream, events) = AsyncThrowingStream<Observation, any Error>.makeStream()
        observations = stream
        let accepted = AcceptedSession()
        self.accepted = accepted
        // Deliberately no listener requirement here: the anonymous fixture must reach the
        // REAL per-message check. Production must apply BOTH requirements, not this fixture.
        let listener = XPCListener { request in
            request.accept { session in
                accepted.value.withLock { $0 = session }
                return Handler(session: session, observations: events)
            }
        }
        do { client = try XPCSession(endpoint: listener.endpoint) }
        catch { listener.cancel(); throw error }
        self.listener = listener
    }

    func request(_ message: XPCDictionary) -> AsyncThrowingStream<Data, any Error> {
        let (stream, answers) = AsyncThrowingStream<Data, any Error>.makeStream()
        client.send(message: message) { result in
            switch result {
            case .success(let reply):
                do {
                    answers.yield(try RawRuntimeFrame.payload(reply, expectedVersion: Int64(RuntimeProtocolVersion.current.rawValue)))
                    answers.finish()
                } catch { answers.finish(throwing: error) }
            case .failure: answers.finish(throwing: FixtureFailure.transport)
            }
        }
        return stream
    }

    func cancel() {
        client.cancel(reason: "caller authentication fixture completed")
        accepted.value.withLock { $0 }?.cancel(reason: "caller authentication fixture completed")
        listener.cancel()
    }
}

private struct Handler: XPCPeerHandler {
    let session: XPCSession
    let observations: AsyncThrowingStream<Observation, any Error>.Continuation

    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        // Authenticate the original native message before consuming its reply context.
        let allowed = RuntimeCallerAuthentication.allows(message)
        let context = RawRuntimeReplyContext(receivedMessage: message)
        if let context {
            do {
                guard let reply = try context.takeReply(
                    payload: Data([allowed ? 1 : 0]), protocolVersion: Int64(RuntimeProtocolVersion.current.rawValue)
                ) else { observations.finish(throwing: FixtureFailure.missingReply); return nil }
                try session.send(message: reply)
            } catch { observations.finish(throwing: FixtureFailure.transport); return nil }
        }
        // Report checker observations only. This fixture does NOT implement production
        // session refusal, admission or operation dispatch; those require their own adapter.
        observations.yield(Observation(allowed: allowed, expectsReply: context != nil))
        return nil
    }
}

private enum FixtureFailure: Error { case timeout, transport, missingReply }

private func next<T: Sendable>(_ stream: AsyncThrowingStream<T, any Error>) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try #require(await iterator.next())
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw FixtureFailure.timeout
        }
        defer { group.cancelAll() }
        return try #require(await group.next())
    }
}
