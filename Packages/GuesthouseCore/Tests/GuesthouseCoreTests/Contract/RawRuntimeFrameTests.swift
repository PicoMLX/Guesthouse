import Foundation
import Testing
import XPC
@testable import GuesthouseCore

@Suite struct RawRuntimeFrameTests {
    // Fixture-only frame epoch. This codec does not activate or select production wire 12.
    let version: Int64 = 12

    @Test(arguments: [1, RawRuntimeFrame.maximumPayloadBytes])
    func acceptedBoundaryDeliversOnlyBoundedBytes(length: Int) throws {
        let expected = Data(repeating: 0x78, count: length)
        let message = try RawRuntimeFrame.encode(expected, protocolVersion: version)
        let actual = try RawRuntimeFrame.withPayloadBytes(message, expectedVersion: version) { Data($0) }
        #expect(actual == expected)
    }

    @Test func oversizedDataNeverReachesCopyOrDecoder() {
        let message = dataFrame(length: RawRuntimeFrame.maximumPayloadBytes + 1)
        var copies = 0
        #expect(throws: RawRuntimeFrame.Failure.oversized) {
            try RawRuntimeFrame.withPayloadBytes(message, expectedVersion: version) { bytes in
                copies += 1
                return Data(bytes)
            }
        }
        #expect(copies == 0)
    }

    @Test func unknownOuterFieldIsRejectedWithoutReadingItsValue() {
        var message = dataFrame(length: 1)
        message["ignored"] = String(repeating: "x", count: RawRuntimeFrame.maximumPayloadBytes + 1)
        expectMalformedBeforeCallback(message)
    }

    @Test func missingKeyIsNotReplacedByAnUnknownKey() {
        var message = XPCDictionary()
        message["protocolVersion"] = version
        message["ignored"] = xpc_data_create(nil, 0)
        expectMalformedBeforeCallback(message)
    }

    @Test func payloadAndVersionMustHaveExactWireTypes() {
        var stringPayload = XPCDictionary()
        stringPayload["protocolVersion"] = version
        stringPayload["payload"] = "not bytes"
        expectMalformedBeforeCallback(stringPayload)
        var unsignedVersion = dataFrame(length: 1)
        unsignedVersion["protocolVersion"] = UInt64(version)
        expectMalformedBeforeCallback(unsignedVersion)
        var stringVersion = dataFrame(length: 1)
        stringVersion["protocolVersion"] = "12"
        expectMalformedBeforeCallback(stringVersion)
    }

    @Test func emptyPayloadAndMissingVersionAreMalformed() {
        expectMalformedBeforeCallback(dataFrame(length: 0))
        var noVersion = XPCDictionary()
        noVersion["payload"] = xpc_data_create(nil, 0)
        expectMalformedBeforeCallback(noVersion)
    }

    @Test func foreignVersionIsReportedBeforeAnUnknownPayloadIsInspected() {
        var message = XPCDictionary()
        message["protocolVersion"] = Int64(99)
        message["payload"] = "future wire representation"
        var calls = 0
        #expect(throws: RawRuntimeFrame.Failure.protocolMismatch(received: 99)) {
            try RawRuntimeFrame.withPayloadBytes(message, expectedVersion: version) { _ in calls += 1 }
        }
        #expect(calls == 0)
    }

    @Test func unknownJSONFieldsStillCountAgainstTheReceivedByteBudget() throws {
        let json = try JSONEncoder().encode(["known": "value", "ignored": String(repeating: "x", count: RawRuntimeFrame.maximumPayloadBytes)])
        var message = XPCDictionary()
        message["protocolVersion"] = version
        message["payload"] = json.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
        var copied = false
        #expect(throws: RawRuntimeFrame.Failure.oversized) {
            try RawRuntimeFrame.withPayloadBytes(message, expectedVersion: version) { bytes in
                copied = true
                return Data(bytes)
            }
        }
        #expect(!copied)
    }

    @Test func publicPayloadIsAnOwnedCopy() throws {
        var message = dataFrame(length: 4)
        let owned = try RawRuntimeFrame.payload(message, expectedVersion: version)
        message["payload"] = xpc_data_create(nil, 0)
        #expect(owned == Data(repeating: 0x78, count: 4))
    }

    @Test func outgoingBoundsFailWithClosedErrors() {
        #expect(throws: RawRuntimeFrame.Failure.malformed) {
            try RawRuntimeFrame.encode(Data(), protocolVersion: version)
        }
        #expect(throws: RawRuntimeFrame.Failure.oversized) {
            try RawRuntimeFrame.encode(Data(repeating: 1, count: 65_537), protocolVersion: version)
        }
    }

    private func dataFrame(length: Int) -> XPCDictionary {
        var message = XPCDictionary()
        message["protocolVersion"] = version
        let data = Data(repeating: 0x78, count: length)
        message["payload"] = data.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
        return message
    }

    private func expectMalformedBeforeCallback(_ message: XPCDictionary) {
        var calls = 0
        #expect(throws: RawRuntimeFrame.Failure.malformed) {
            try RawRuntimeFrame.withPayloadBytes(message, expectedVersion: version) { _ in calls += 1 }
        }
        #expect(calls == 0)
    }
}
