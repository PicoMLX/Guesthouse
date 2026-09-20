import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeRequestTests {
    static let environment = EnvironmentID()
    static let operation = OperationID()
    static let requests: [RuntimeRequest] = [
        .runtimeVersion, .hostPreflight, .environmentStatus(environment), .cancelOperation(operation),
        .startEnvironment(environment, StartOptions()),
        .startEnvironment(environment, StartOptions(console: .native, ipWait: .seconds(120))),
        .stopEnvironment(environment, .graceful(deadline: .seconds(60))),
        .stopEnvironment(environment, .force),
        .importXcode(environment, FileHandoff(kind: .securityScopedBookmark(Data([1, 2, 3])),
                                            displayName: "Xcode.app", expectedBundleIdentifier: "com.apple.dt.Xcode")),
        .importXcode(environment, FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app")),
    ]

    @Test(arguments: requests)
    func requestsRoundTrip(request: RuntimeRequest) throws {
        let envelope = RuntimeRequestEnvelope(request: request)
        let data = try JSONEncoder().encode(envelope)
        #expect(try RequestValidator.decode(data) == envelope)
        #expect(envelope.protocolVersion.rawValue == 13)
    }

    @Test(arguments: requests, ["executable", "arguments", "command", "shell", "--", "/bin/"])
    func requestVocabularyHasNoExecutionAPI(request: RuntimeRequest, forbidden: String) throws {
        let data = try JSONEncoder().encode(request)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains(forbidden))
    }

    @Test(arguments: [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, Int.max])
    func foreignVersionPrecedesUnknownPayload(version: Int) {
        let data = Data("{\"protocolVersion\":\(version),\"request\":{\"futureRequest\":{}}}".utf8)
        let expected = RequestValidationError.protocolMismatch(client: RuntimeProtocolVersion(version), service: .current)
        #expect(throws: expected) { try RequestValidator.decode(data) }
        #expect(expected.guesthouseError == .protocolMismatch(client: version, service: 13))
    }

    @Test func directEnvelopeDecoderAlsoChecksHeaderFirst() throws {
        let data = Data(#"{"protocolVersion":7}"#.utf8)
        let error = try #require(throws: RuntimeRequestEnvelope.ProtocolMismatch.self) {
            try JSONDecoder().decode(RuntimeRequestEnvelope.self, from: data)
        }
        #expect(error.error == .protocolMismatch(client: 7, service: 13))
    }

    @Test(arguments: ["{}", "null", #"{"request":{"runtimeVersion":{}}}"#,
                      #"{"protocolVersion":"13","request":{}}"#, #"{"protocolVersion":13}"#,
                      #"{"protocolVersion":13,"request":{"runCommand":{"command":"private-marker"}}}"#])
    func malformedRequestsAreTyped(json: String) {
        #expect(throws: RequestValidationError.malformed) { try RequestValidator.decode(Data(json.utf8)) }
    }

    @Test func encodedSizeIsCheckedBeforeParsing() throws {
        var data = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .runtimeVersion))
        data.append(Data(repeating: 32, count: 65_536 - data.count))
        #expect(try RequestValidator.decode(data).request == .runtimeVersion)
        data.append(0) // Also invalid JSON: size must take precedence over parsing.
        #expect(throws: RequestValidationError.oversized(bytes: 65_537, limit: 65_536)) {
            try RequestValidator.decode(data)
        }
    }

    @Test(arguments: [Duration.zero, .seconds(300)])
    func ipWaitEndpointsAreAccepted(wait: Duration) throws {
        try RequestValidator.validate(RuntimeRequestEnvelope(request: .startEnvironment(Self.environment, StartOptions(ipWait: wait))))
    }

    @Test(arguments: [Duration.seconds(-1), .seconds(301)])
    func ipWaitOutsideRangeIsRejected(wait: Duration) throws {
        let data = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .startEnvironment(Self.environment, StartOptions(ipWait: wait))))
        #expect(throws: RequestValidationError.optionOutOfRange(.ipWait)) { try RequestValidator.decode(data) }
    }

    @Test(arguments: [Duration.nanoseconds(1), .seconds(600)])
    func gracefulDeadlineEndpointsAreAccepted(deadline: Duration) throws {
        try RequestValidator.validate(RuntimeRequestEnvelope(request: .stopEnvironment(Self.environment, .graceful(deadline: deadline))))
    }

    @Test(arguments: [Duration.seconds(-1), .zero, .seconds(601)])
    func gracefulDeadlineOutsideRangeIsRejected(deadline: Duration) throws {
        let data = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .stopEnvironment(Self.environment, .graceful(deadline: deadline))))
        #expect(throws: RequestValidationError.optionOutOfRange(.gracefulStopDeadline)) { try RequestValidator.decode(data) }
    }

    @Test func programmaticEnvelopeMustAlsoMatchProtocol() {
        #expect(throws: RequestValidationError.protocolMismatch(client: RuntimeProtocolVersion(7), service: .current)) {
            try RequestValidator.validate(RuntimeRequestEnvelope(protocolVersion: RuntimeProtocolVersion(7), request: .runtimeVersion))
        }
    }

    @Test(arguments: [1, 16_384])
    func bookmarkSizeEndpointsAreAccepted(count: Int) throws {
        try RequestValidator.validate(FileHandoff(kind: .securityScopedBookmark(Data(repeating: 1, count: count)), displayName: "Xcode.app"))
    }

    @Test func emptyAndOversizedBookmarksAreRejected() throws {
        #expect(throws: RequestValidationError.invalidHandoff) {
            try RequestValidator.validate(FileHandoff(kind: .securityScopedBookmark(Data()), displayName: "Xcode.app"))
        }
        let handoff = FileHandoff(kind: .securityScopedBookmark(Data(repeating: 1, count: 16_385)), displayName: "Xcode.app")
        let data = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .importXcode(Self.environment, handoff)))
        #expect(throws: RequestValidationError.oversized(bytes: 16_385, limit: 16_384)) { try RequestValidator.decode(data) }
    }

    @Test(arguments: ["", ".", "..", "../Xcode.app", "Applications/Xcode.app", "Xcode\n.app",
                      "Xcode\u{2028}.app", "Xcode\u{2029}.app", "Xcode\u{202E}.app", "Xcode\u{1B}.app",
                      String(repeating: "x", count: 256), "👩" + String(repeating: "\u{1F3FB}", count: 5_000)])
    func invalidDisplayNamesAreRejected(name: String) throws {
        let handoff = FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: name)
        let data = try JSONEncoder().encode(RuntimeRequestEnvelope(request: .importXcode(Self.environment, handoff)))
        #expect(throws: RequestValidationError.invalidDisplayName) { try RequestValidator.decode(data) }
    }

    @Test(arguments: ["Xcode.app", "Cafe\u{301}.app", "Private-Marker.app", String(repeating: "😀", count: 255)])
    func privateSelectionNamesArePreservedNotRedacted(name: String) throws {
        let request = RuntimeRequest.importXcode(Self.environment, FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: name))
        let data = try JSONEncoder().encode(RuntimeRequestEnvelope(request: request))
        #expect(try RequestValidator.decode(data).request == request)
    }

    @Test(arguments: ["", "com..apple", ".com.apple", "com.apple.", "com/apple", "com.äpple", "com.\napp", String(repeating: "a", count: 256)])
    func malformedBundleHintsAreRejected(hint: String) {
        let handoff = FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app", expectedBundleIdentifier: hint)
        #expect(throws: RequestValidationError.invalidBundleIdentifier) { try RequestValidator.validate(handoff) }
    }

    @Test(arguments: ["com.apple.dt.Xcode", "com.example.beta-1", String(repeating: "a", count: 255)])
    func boundedBundleHintsRemainPrivateHints(hint: String) throws {
        let request = RuntimeRequest.importXcode(Self.environment, FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app", expectedBundleIdentifier: hint))
        #expect(try RequestValidator.decode(JSONEncoder().encode(RuntimeRequestEnvelope(request: request))).request == request)
    }

    @Test func unknownMetadataIsNotForwarded() throws {
        let data = Data(#"{"protocolVersion":13,"private":"private-marker","request":{"runtimeVersion":{}}}"#.utf8)
        let encoded = try JSONEncoder().encode(RequestValidator.decode(data))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private-marker"))
    }

    @Test func malformedInputCannotReachStructuredErrorsOrExports() throws {
        let data = Data(#"{"protocolVersion":13,"request":{"private-marker":{}}}"#.utf8)
        let rejection = try #require(throws: RequestValidationError.self) { try RequestValidator.decode(data) }
        #expect(rejection.guesthouseError == .invalidRequest(.malformed))
        let event = DiagnosticEvent(operation: .importXcode, outcome: .init(error: rejection.guesthouseError), operationID: UUID())
        var log = DiagnosticLog()
        log.append(event)
        #expect(!event.message.contains("private-marker"))
        #expect(!log.text.contains("private-marker"))
        #expect(!String(decoding: try log.jsonData(), as: UTF8.self).contains("private-marker"))
        #expect(!rejection.guesthouseError.recoveryActions.isEmpty)
    }
}
