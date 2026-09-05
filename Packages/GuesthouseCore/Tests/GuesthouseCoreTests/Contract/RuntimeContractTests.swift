import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeContractTests {
    static let environment = EnvironmentID()
    static let operation = OperationID()

    static let requests: [RuntimeRequest] = [
        .runtimeVersion,
        .environmentStatus(environment),
        .startEnvironment(environment, StartOptions()),
        .startEnvironment(environment, StartOptions(console: .native, ipWait: .seconds(120))),
        .stopEnvironment(environment, .graceful(deadline: .seconds(60))),
        .stopEnvironment(environment, .force),
        .importXcode(environment, FileHandoff(kind: .securityScopedBookmark(Data(repeating: 7, count: 512)), displayName: "Xcode.app", expectedBundleIdentifier: "com.apple.dt.Xcode")),
        .importXcode(environment, FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app")),
        .cancelOperation(operation),
    ]

    static let events: [RuntimeEvent] = [
        .runtimeVersion(RuntimeVersionInfo(serviceVersion: "0.1.0", serviceBuild: "12", tart: .init(version: "2.36.0", verified: true))),
        .accepted(operation),
        .progress(operation, ProgressPhase(kind: .waitingForNetwork, fraction: 0.5)),
        .progress(operation, ProgressPhase(kind: .copying, fraction: nil, cancelable: false)),
        .log(operation, RedactedLine(literal: "Started")),
        .log(nil, RedactedLine(literal: "Service launched")),
        .status(EnvironmentStatus(environmentID: environment, vm: .running, readiness: .ready, inFlightOperation: operation, observed: ObservedTuple(tartVersion: "2.36.0"), reconciledAt: Date(timeIntervalSince1970: 1_800_000_000))),
        .status(EnvironmentStatus(environmentID: environment, vm: .uncertain(reason: "pid reused"), readiness: .needsAttention(.operationOutcomeUnknown(operation)))),
        .completed(operation),
        .failed(operation, .guestNotReachable(environment)),
    ]

    @Test(arguments: requests)
    func requestsRoundTrip(request: RuntimeRequest) throws {
        let envelope = RuntimeRequestEnvelope(request: request)
        let data = try JSONEncoder().encode(envelope)
        #expect(try JSONDecoder().decode(RuntimeRequestEnvelope.self, from: data) == envelope)
        try RequestValidator.validateEncodedSize(data)
        try RequestValidator.validate(envelope)
    }

    @Test(arguments: events)
    func eventsRoundTrip(event: RuntimeEvent) throws {
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(RuntimeEvent.self, from: data) == event)
    }

    @Test func noRequestCarriesAnExecutableOrFlag() throws {
        for request in Self.requests {
            let data = try JSONEncoder().encode(request)
            let json = String(decoding: data, as: UTF8.self).lowercased()
            for forbidden in ["executable", "argument", "command", "shell", "flag", "--", "/bin/", "/usr/"] {
                #expect(!json.contains(forbidden), "\(request.caseName) contains \(forbidden)")
            }
        }
    }

    @Test func wrongProtocolVersionIsRejected() {
        let envelope = RuntimeRequestEnvelope(protocolVersion: RuntimeProtocolVersion(99), request: .runtimeVersion)
        #expect(throws: RequestValidationError.protocolMismatch(client: RuntimeProtocolVersion(99), service: .current)) {
            try RequestValidator.validate(envelope)
        }
        #expect(RequestValidationError.protocolMismatch(client: RuntimeProtocolVersion(99), service: .current).guesthouseError
            == .protocolMismatch(client: 99, service: RuntimeProtocolVersion.current.rawValue))
    }

    @Test func oversizedMessagesAreRejectedBeforeDecoding() {
        let big = Data(repeating: 0x20, count: RequestValidator.maximumEncodedSize + 1)
        #expect(throws: RequestValidationError.oversized(bytes: big.count, limit: RequestValidator.maximumEncodedSize)) {
            try RequestValidator.validateEncodedSize(big)
        }
        let bigBookmark = FileHandoff(kind: .securityScopedBookmark(Data(repeating: 1, count: RequestValidator.maximumBookmarkSize + 1)), displayName: "Xcode.app")
        #expect(throws: RequestValidationError.self) {
            try RequestValidator.validate(RuntimeRequestEnvelope(request: .importXcode(Self.environment, bigBookmark)))
        }
        let emptyBookmark = FileHandoff(kind: .securityScopedBookmark(Data()), displayName: "Xcode.app")
        #expect(throws: RequestValidationError.self) {
            try RequestValidator.validate(emptyBookmark)
        }
    }

    @Test func optionBoundsAreEnforced() {
        #expect(throws: RequestValidationError.optionOutOfRange("ipWait")) {
            try RequestValidator.validate(RuntimeRequestEnvelope(request: .startEnvironment(Self.environment, StartOptions(ipWait: .seconds(301)))))
        }
        #expect(throws: RequestValidationError.optionOutOfRange("deadline")) {
            try RequestValidator.validate(RuntimeRequestEnvelope(request: .stopEnvironment(Self.environment, .graceful(deadline: .zero))))
        }
    }

    @Test func displayNamesCannotBePaths() {
        for bad in ["", "../Xcode.app", "Applications/Xcode.app", "Xcode\n.app", String(repeating: "x", count: 256)] {
            #expect(throws: RequestValidationError.invalidDisplayName) {
                try RequestValidator.validate(FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: bad))
            }
        }
    }

    @Test func vmNamesMustBeAppManaged() throws {
        try RequestValidator.validateVMName(EnvironmentID().tartVMName)
        for bad in ["guesthouse-1a2b3c4d", "GUESTHOUSE-\(UUID().uuidString.lowercased())", "guesthouse-\(UUID().uuidString)", "../\(EnvironmentID().tartVMName)", "ubuntu", ""] {
            #expect(throws: RequestValidationError.invalidVMName, "\(bad)") {
                try RequestValidator.validateVMName(bad)
            }
        }
    }

    @Test func containmentFollowsSymlinksAndRejectsEscapes() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "containment-\(UUID().uuidString)")
        let root = base.appending(path: "root")
        let sibling = base.appending(path: "root-sibling")
        let outside = base.appending(path: "outside")
        for dir in [root, sibling, outside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let inside = root.appending(path: "Xcode.app")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let escapeLink = root.appending(path: "escape")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outside)
        let innerLink = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: innerLink, withDestinationURL: inside)

        #expect(try RequestValidator.validateContainment(of: inside, within: root).lastPathComponent == "Xcode.app")
        #expect(try RequestValidator.validateContainment(of: innerLink, within: root).lastPathComponent == "Xcode.app")
        #expect(throws: RequestValidationError.pathEscapesRoot) {
            try RequestValidator.validateContainment(of: escapeLink, within: root)
        }
        #expect(throws: RequestValidationError.pathEscapesRoot) {
            try RequestValidator.validateContainment(of: escapeLink.appending(path: "file"), within: root)
        }
        #expect(throws: RequestValidationError.pathEscapesRoot) {
            try RequestValidator.validateContainment(of: root.appending(path: "../outside"), within: root)
        }
        #expect(throws: RequestValidationError.pathEscapesRoot) {
            try RequestValidator.validateContainment(of: sibling, within: root)
        }
        #expect(throws: RequestValidationError.invalidPath) {
            try RequestValidator.validateContainment(of: URL(string: "https://example.com")!, within: root)
        }
    }

    @Test func validationErrorsMapToUserFacingErrors() {
        #expect(RequestValidationError.pathEscapesRoot.guesthouseError == .invalidRequest(.pathEscapesAllowedRoot))
        #expect(RequestValidationError.invalidVMName.guesthouseError == .invalidRequest(.invalidVMName))
        #expect(RequestValidationError.oversized(bytes: 1, limit: 0).guesthouseError == .invalidRequest(.oversized))
    }
}
