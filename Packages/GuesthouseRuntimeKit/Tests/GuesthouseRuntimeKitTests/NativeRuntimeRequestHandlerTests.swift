import Foundation
import GuesthouseCore
import Synchronization
import Testing
import XPC
@testable import GuesthouseRuntimeKit

/// Actual anonymous delivery, with explicitly injected authentication for positive ingress
/// cases. This is not signed-GUI, production activation, streaming or host-mutation proof.
@Suite(.timeLimit(.minutes(1))) struct NativeRuntimeRequestHandlerTests {
    enum Shape: Sendable, CaseIterable {
        case current, exactBoundary, empty, oversized, ignoredJSON, unknownOuter, missingPayload, missingHeader
        case wrongPayload, wrongHeader, foreignHeader, contradictoryInner, malformedJSON
    }

    @Test(arguments: Shape.allCases)
    func validatesOriginalFrameBeforePayloadDecoder(shape: Shape) async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        let reply = try await next(fixture.request(try message(shape)))
        _ = try await next(fixture.processed)
        let trace = fixture.trace.steps.withLock { $0 }
        #expect(trace.first == .authenticated)
        switch shape {
        case .current, .exactBoundary:
            #expect(reply == .runtimeVersion(version))
            #expect(trace == [.authenticated, .decoded, .registered, .sendAttempt, .sent])
        case .malformedJSON, .contradictoryInner:
            #expect(failure(reply) == .invalidRequest(.malformed))
            #expect(trace.contains(.decoded) && !trace.contains(.registered))
        case .foreignHeader:
            #expect(failure(reply) == .protocolMismatch(client: 99, service: RuntimeProtocolVersion.current.rawValue))
            #expect(!trace.contains(.decoded) && trace.suffix(2) == [.sent, .canceled])
        default:
            let expected: GuesthouseError = [.oversized, .ignoredJSON].contains(shape)
                ? .invalidRequest(.oversized) : .invalidRequest(.malformed)
            #expect(failure(reply) == expected)
            #expect(!trace.contains(.decoded) && !trace.contains(.registered))
        }
        // Only Guesthouse-built closed records leave the boundary, never ignored raw fields.
        for diagnostic in fixture.trace.diagnostics.withLock({ $0 }) {
            #expect(diagnostic.operation == .runtimeRequest)
            #expect(!diagnostic.message.contains("private-fixture-marker"))
        }
    }

    @Test(arguments: [false, true])
    func unauthorizedTrafficRefusesBeforeDecodeAndHandsReplyBeforeCancel(oneWay: Bool) async throws {
        let fixture = try Fixture(authorized: false)
        defer { fixture.cancel() }
        if oneWay { try fixture.client.send(message: try message(.unknownOuter)) }
        else { #expect(failure(try await next(fixture.request(try message(.unknownOuter)))) == .unauthorizedCaller) }
        _ = try await next(fixture.processed)
        let trace = fixture.trace.steps.withLock { $0 }
        #expect(!trace.contains(.decoded) && !trace.contains(.registered))
        #expect(trace == (oneWay ? [.authenticated, .diagnostic, .canceled]
            : [.authenticated, .diagnostic, .sendAttempt, .sent, .canceled]))
    }

    @Test func publicInitializerUsesRealAuthentication() async throws {
        let fixture = try Fixture(usePublicPolicy: true)
        defer { fixture.cancel() }
        let event = try await next(fixture.request(try message(.current)))
        #expect(failure(event) == .unauthorizedCaller)
        // The standalone runner is not the GUI. A rejection is not positive signing proof.
    }

    @Test func productionRegistrationSupportsOnlyTheReadOnlyVersionQuery() {
        let environment = EnvironmentID()
        let requests: [RuntimeRequest] = [
            .environmentStatus(environment), .startEnvironment(environment, StartOptions()),
            .stopEnvironment(environment, .force), .cancelOperation(OperationID()),
            .importXcode(environment, FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app")),
        ]
        for request in requests {
            #expect(failure(NativeRuntimeRequestHandler.queryReply(request, version: version)) == .invalidRequest(.unsupportedOperation))
        }
        #expect(NativeRuntimeRequestHandler.queryReply(.runtimeVersion, version: version) == .runtimeVersion(version))
    }

    @Test func oneWayDoesNotDecodeOrStealFollowingReply() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        try fixture.client.send(message: try message(.ignoredJSON))
        _ = try await next(fixture.processed)
        #expect(fixture.trace.steps.withLock { $0 } == [.authenticated, .diagnostic])
        #expect(try await next(fixture.request(try message(.current))) == .runtimeVersion(version))
    }

    @Test func simultaneousNativeRepliesStayWithTheirRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.cancel() }
        try await withThrowingTaskGroup(of: (Bool, RuntimeEvent).self) { group in
            for index in 0..<4 {
                group.addTask {
                    let query = index.isMultiple(of: 2)
                    let request: RuntimeRequest = query ? .runtimeVersion : .environmentStatus(EnvironmentID())
                    let bytes = try JSONEncoder().encode(RuntimeRequestEnvelope(request: request))
                    let frame = try RawRuntimeFrame.encode(bytes, protocolVersion: Int64(RuntimeProtocolVersion.current.rawValue))
                    return (query, try await next(fixture.request(frame)))
                }
            }
            for try await (query, event) in group {
                if query { #expect(event == .runtimeVersion(version)) }
                else { #expect(failure(event) == .invalidRequest(.unsupportedOperation)) }
            }
        }
    }

    @Test func capChecksNativeHeaderWithoutCopyingOrDecodingPayload() async throws {
        let gate = RuntimeSessionGate()
        for _ in 0..<RuntimeDispatcher.maximumInFlightRequestsPerSession { _ = try #require(gate.began()) }
        let fixture = try Fixture(gate: gate)
        defer { fixture.cancel() }
        #expect(failure(try await next(fixture.request(try message(.ignoredJSON)))) == .invalidRequest(.tooManyInFlight))
        _ = try await next(fixture.processed)
        #expect(!fixture.trace.steps.withLock { $0.contains(.decoded) || $0.contains(.registered) })
        // Release the synthetic already-counted callbacks; native tests above cover real replies.
        for _ in 0..<RuntimeDispatcher.maximumInFlightRequestsPerSession { #expect(!gate.finished()) }
    }

    @Test func refusalBetweenDecodeAndCommitPreventsRegistration() async throws {
        let fixture = try Fixture(refuseDuringDecode: true)
        defer { fixture.cancel() }
        #expect(failure(try await next(fixture.request(try message(.current)))) == .unauthorizedCaller)
        _ = try await next(fixture.processed)
        #expect(!fixture.trace.steps.withLock { $0.contains(.registered) })
        #expect(fixture.trace.steps.withLock { Array($0.suffix(2)) } == [.sent, .canceled])
    }

    @Test func replyEncodingFailureKeepsContextForTypedQueryFailure() async throws {
        let fixture = try Fixture(badVersion: true)
        defer { fixture.cancel() }
        let reply = try await next(fixture.request(try message(.current)))
        #expect(failure(reply) == .invalidRuntimeReply(.malformed))
        _ = try await next(fixture.processed)
        #expect(fixture.trace.steps.withLock { $0.filter { $0 == .sendAttempt }.count } == 1)
        #expect(fixture.trace.steps.withLock { Array($0.suffix(2)) } == [.sent, .canceled])
    }

    @Test func sendFailureRetiresWithoutRetryingOrReclaimingReply() async throws {
        let fixture = try Fixture(failSend: true)
        defer { fixture.cancel() }
        await #expect(throws: FixtureFailure.transport) { try await next(fixture.request(try message(.current))) }
        _ = try await next(fixture.processed)
        #expect(fixture.trace.steps.withLock { $0.filter { $0 == .sendAttempt }.count } == 1)
        #expect(fixture.trace.steps.withLock { $0.last } == .canceled)
        // Once refused, even a further direct callback cannot decode, register or cancel twice.
        let before = fixture.trace.steps.withLock { $0 }
        _ = fixture.state.handler.withLock { $0 }?.handleIncomingRequest(try message(.current))
        #expect(fixture.trace.steps.withLock { $0 } == before)
    }

    private func message(_ shape: Shape) throws -> XPCDictionary {
        var result = XPCDictionary()
        result["protocolVersion"] = Int64(RuntimeProtocolVersion.current.rawValue)
        var bytes = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .runtimeVersion))
        switch shape {
        case .exactBoundary: bytes.append(Data(repeating: 32, count: 65_536 - bytes.count))
        case .empty: bytes = Data()
        case .oversized: bytes = Data(repeating: 32, count: 65_537)
        case .ignoredJSON:
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["ignored"] = String(repeating: "x", count: 65_537)
            bytes = try JSONSerialization.data(withJSONObject: object)
        case .contradictoryInner: bytes = try JSONEncoder().encode(RuntimeRequestEnvelope(protocolVersion: .init(99), request: .runtimeVersion))
        case .malformedJSON: bytes = Data("{".utf8)
        default: break
        }
        if shape != .missingPayload { result["payload"] = bytes.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) } }
        if shape == .unknownOuter { result["ignored"] = "private-fixture-marker" + String(repeating: "x", count: 65_537) }
        if shape == .wrongPayload { result["payload"] = "not bytes" }
        if shape == .wrongHeader { result["protocolVersion"] = "not an integer" }
        if shape == .missingHeader { result.withUnsafeUnderlyingDictionary { xpc_dictionary_set_value($0, "protocolVersion", nil) } }
        if shape == .foreignHeader { result["protocolVersion"] = Int64(99); result["payload"] = "unknown future format" }
        return result
    }

    private func failure(_ event: RuntimeEvent) -> GuesthouseError? {
        if case .failed(_, let error) = event { error } else { nil }
    }
}

private let version = RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1")
private enum Step { case authenticated, decoded, registered, diagnostic, sendAttempt, sent, canceled }
private final class Trace: Sendable {
    let steps = Mutex<[Step]>([])
    let diagnostics = Mutex<[DiagnosticEvent]>([])
    func record(_ step: Step) { steps.withLock { $0.append(step) } }
}

private final class Fixture: Sendable {
    let trace = Trace()
    let state = SessionState()
    let listener: XPCListener
    let client: XPCSession
    let processed: AsyncThrowingStream<Bool, any Error>

    init(authorized: Bool = true, usePublicPolicy: Bool = false, gate: RuntimeSessionGate = RuntimeSessionGate(),
         refuseDuringDecode: Bool = false, badVersion: Bool = false, failSend: Bool = false) throws {
        let (stream, completion) = AsyncThrowingStream<Bool, any Error>.makeStream()
        processed = stream
        let trace = trace, state = state
        let listener = XPCListener { request in
            request.accept { session in
                state.accepted.withLock { $0 = session }
                let log: @Sendable (DiagnosticEvent) -> Void = { event in
                    trace.record(.diagnostic); trace.diagnostics.withLock { $0.append(event) }
                }
                let native: NativeRuntimeRequestHandler
                if usePublicPolicy { native = NativeRuntimeRequestHandler(session: session, version: version, diagnostic: log) }
                else {
                    native = NativeRuntimeRequestHandler(gate: gate,
                        authenticate: { _ in trace.record(.authenticated); return authorized },
                        decode: { bytes, count in
                            trace.record(.decoded)
                            if refuseDuringDecode { gate.refuse(.failed(OperationID(), .unauthorizedCaller)) }
                            return RuntimeDispatcher.decide(bytes, inFlight: count)
                        },
                        register: { request in
                            trace.record(.registered)
                            return NativeRuntimeRequestHandler.queryReply(request, version: badVersion
                                ? RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1", protocolVersion: .init(99)) : version)
                        },
                        send: { reply in
                            trace.record(.sendAttempt)
                            if failSend { throw FixtureFailure.transport }
                            try session.send(message: reply); trace.record(.sent)
                        },
                        cancel: { trace.record(.canceled); session.cancel(reason: "test refusal") }, diagnostic: log)
                }
                state.handler.withLock { $0 = native }
                return ObservingHandler(native: native, completion: completion)
            }
        }
        do { client = try XPCSession(endpoint: listener.endpoint) }
        catch { listener.cancel(); throw error }
        self.listener = listener
    }

    func request(_ message: XPCDictionary) -> AsyncThrowingStream<RuntimeEvent, any Error> {
        let (stream, replies) = AsyncThrowingStream<RuntimeEvent, any Error>.makeStream()
        client.send(message: message) { response in
            do {
                let native = try response.get()
                let bytes = try RawRuntimeFrame.payload(native, expectedVersion: Int64(RuntimeProtocolVersion.current.rawValue))
                replies.yield(try RuntimeEventEnvelope.decode(bytes).event); replies.finish()
            } catch { replies.finish(throwing: FixtureFailure.transport) }
        }
        return stream
    }

    func cancel() {
        client.cancel(reason: "test completed")
        state.accepted.withLock { $0 }?.cancel(reason: "test completed")
        listener.cancel()
    }
}

private final class SessionState: Sendable {
    let handler = Mutex<NativeRuntimeRequestHandler?>(nil)
    let accepted = Mutex<XPCSession?>(nil)
}

private struct ObservingHandler: XPCPeerHandler {
    let native: NativeRuntimeRequestHandler
    let completion: AsyncThrowingStream<Bool, any Error>.Continuation
    func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
        let result = native.handleIncomingRequest(message)
        #expect(result == nil)
        completion.yield(true)
        return nil
    }
    func handleCancellation(error: XPCRichError) { native.handleCancellation(error: error) }
}
private enum FixtureFailure: Error { case transport, timeout }
private func next<T: Sendable>(_ stream: AsyncThrowingStream<T, any Error>) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { var iterator = stream.makeAsyncIterator(); return try #require(await iterator.next()) }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw FixtureFailure.timeout }
        defer { group.cancelAll() }
        return try #require(await group.next())
    }
}
