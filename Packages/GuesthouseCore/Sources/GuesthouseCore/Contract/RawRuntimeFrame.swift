import Foundation
import XPC

/// Fixed-schema native XPC frame validation for #112 / MVP-PLAN.md §3.
/// No endpoint is activated here. The transport must authenticate the received message FIRST,
/// choose its agreed wire epoch, and validate nested request/event versions after framing.
public enum RawRuntimeFrame: Sendable {
    public static let maximumPayloadBytes = 64 * 1024

    public enum Failure: Error, Hashable, Sendable {
        case malformed, oversized
        case protocolMismatch(received: Int64)
    }

    /// Returns an owned, bounded copy. Native type/count/length checks happen before copying
    /// or JSON decoding. This does NOT bound libxpc's initial receive allocation or authenticate
    /// the caller. Do not concurrently mutate the dictionary while validating it.
    public static func payload(_ message: XPCDictionary, expectedVersion: Int64) throws(Failure) -> Data {
        try withPayloadBytes(message, expectedVersion: expectedVersion) { Data($0) }
    }

    /// Internal test seam: the pointer stays inside the retained dictionary's scope. Only
    /// payload() exposes this publicly, as owned Data; no borrowed pointer escapes that API.
    static func withPayloadBytes<ResultValue>(
        _ message: XPCDictionary,
        expectedVersion: Int64,
        _ body: (UnsafeRawBufferPointer) -> ResultValue
    ) throws(Failure) -> ResultValue {
        let result: Result<ResultValue, Failure> = message.withUnsafeUnderlyingDictionary { dictionary in
            guard let header = xpc_dictionary_get_value(dictionary, "protocolVersion"),
                  xpc_get_type(header) == XPC_TYPE_INT64 else { return .failure(.malformed) }
            let received = xpc_int64_get_value(header)
            guard received == expectedVersion else { return .failure(.protocolMismatch(received: received)) }
            // Two fixed keys plus the exact count reject unknown fields without copying
            // attacker-controlled keys/values into Swift strings or collections.
            guard xpc_dictionary_get_count(dictionary) == 2,
                  let payload = xpc_dictionary_get_value(dictionary, "payload"),
                  xpc_get_type(payload) == XPC_TYPE_DATA else { return .failure(.malformed) }
            let length = xpc_data_get_length(payload)
            guard length <= maximumPayloadBytes else { return .failure(.oversized) }
            guard length > 0, let pointer = xpc_data_get_bytes_ptr(payload) else { return .failure(.malformed) }
            return .success(body(UnsafeRawBufferPointer(start: pointer, count: length)))
        }
        return try result.get()
    }

    /// Frames already encoded bytes, not arbitrary Codable objects or a command interface.
    /// The caller owns bounded encoding, version consistency and typed error presentation.
    public static func encode(_ payload: Data, protocolVersion: Int64) throws(Failure) -> XPCDictionary {
        guard payload.count <= maximumPayloadBytes else { throw .oversized }
        guard !payload.isEmpty else { throw .malformed }
        var result = XPCDictionary()
        result["protocolVersion"] = protocolVersion
        result["payload"] = payload.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
        return result
    }
}
