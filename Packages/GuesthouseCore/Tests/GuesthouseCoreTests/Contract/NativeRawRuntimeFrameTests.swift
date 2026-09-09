import Foundation
import Testing
import XPC
@testable import GuesthouseCore

/// Anonymous endpoints test real native delivery, not signing identity, app activation,
/// explicit reply-context ownership, one-way authentication or production epoch selection.
@Suite(.timeLimit(.minutes(1))) struct NativeRawRuntimeFrameTests {
    enum Fixture: Sendable { case bounded, exactBoundary, empty, oversizedData, unknownOuterField, oversizedIgnoredJSON, foreignHeader, wrongPayload }

    @Test(arguments: [
        (Fixture.bounded, true, Int64(0)), (.exactBoundary, true, 0), (.empty, false, 1), (.oversizedData, false, 2),
        (.unknownOuterField, false, 1), (.oversizedIgnoredJSON, false, 2),
        (.foreignHeader, false, 3), (.wrongPayload, false, 1)
    ])
    func nativeDeliveryChecksFrameBeforePayloadDecode(fixture: Fixture, expectedDecode: Bool, expectedFailure: Int64) async throws {
        let listener = XPCListener { request in
            request.accept { (received: XPCDictionary) -> XPCDictionary? in
                var answer = XPCDictionary()
                var decoded = false
                var failure: Int64 = 0
                do {
                    let bytes = try RawRuntimeFrame.payload(received, expectedVersion: 12)
                    decoded = true
                    _ = try JSONDecoder().decode([String: String].self, from: bytes)
                } catch let error as RawRuntimeFrame.Failure {
                    switch error {
                    case .malformed: failure = 1
                    case .oversized: failure = 2
                    case .protocolMismatch: failure = 3
                    }
                } catch { failure = 4 }
                answer["failure"] = failure
                answer["decoded"] = decoded
                return answer
            }
        }
        defer { listener.cancel() }
        let session = try XPCSession(endpoint: listener.endpoint)
        defer { session.cancel(reason: "native frame test completed") }
        var message = XPCDictionary()
        message["protocolVersion"] = Int64(12)
        var json = try JSONEncoder().encode(["known": "value"])
        switch fixture {
        case .bounded, .foreignHeader, .wrongPayload: break
        case .exactBoundary: json.append(Data(repeating: 32, count: RawRuntimeFrame.maximumPayloadBytes - json.count))
        case .empty: json = Data()
        case .oversizedData: json = Data(repeating: 0x78, count: 65_537)
        case .unknownOuterField: message["ignored"] = String(repeating: "x", count: 65_537)
        case .oversizedIgnoredJSON:
            json = try JSONEncoder().encode(["known": "value", "ignored": String(repeating: "x", count: 65_537)])
        }
        message["payload"] = json.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
        if fixture == .foreignHeader { message["protocolVersion"] = Int64(99) }
        if fixture == .wrongPayload { message["payload"] = "not bytes" }
        let result: Delivery = try await withCheckedThrowingContinuation { continuation in
            session.send(message: message) { response in
                switch response {
                case .success(let reply):
                    continuation.resume(returning: Delivery(
                        decoded: reply["decoded", as: Bool.self],
                        failure: reply["failure", as: Int64.self]
                    ))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        #expect(result.decoded == expectedDecode)
        #expect(result.failure == expectedFailure)
    }

    private struct Delivery: Sendable {
        let decoded: Bool?
        let failure: Int64?
    }
}
