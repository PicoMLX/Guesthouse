import Foundation
import GuesthouseCore
import Testing

@Suite struct JournalTailPrefixTests {
    @Test(arguments: JournalOperation.allCases)
    func everyInterruptedOperationEncodingRemainsRecoverable(operation: JournalOperation) throws {
        let record = JournalRecord(id: OperationID(), environmentID: EnvironmentID(),
                                   operation: operation, timestamp: Date(timeIntervalSinceReferenceDate: -0.25),
                                   outcome: .started)
        try checkEveryCut(record)
    }

    @Test(arguments: [JournalOperation.startEnvironment, .provision(stage: .preflight)], [false, true])
    func inconsistentCheckpointTailCannotAuthorizeRepair(operation: JournalOperation, outcomeFirst: Bool) throws {
        let operationJSON = String(decoding: try JSONEncoder().encode(operation), as: UTF8.self)
        let outcomeJSON = String(decoding: try JSONEncoder().encode(JournalRecord.Outcome.checkpoint(.ready)), as: UTF8.self)
        let fields = ["\"operation\":" + operationJSON, "\"outcome\":" + outcomeJSON]
        let ordered = outcomeFirst ? Array(fields.reversed()) : fields
        let tail = Data(("{" + ordered.joined(separator: ",")).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(tail) }
    }

    @Test(arguments: ["operationOutcomeUnknown", "guestNotReachable", "hostKeyChanged"], [false, true])
    func inconsistentEmbeddedIdentityCannotAuthorizeRepair(error: String, outcomeFirst: Bool) throws {
        let original = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let different = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let operation = OperationID(uuid: original), environment = EnvironmentID(uuid: original)
        let reportedOperation = OperationID(uuid: different), reportedEnvironment = EnvironmentID(uuid: different)
        let outcome: JournalRecord.Outcome
        let key: String, identity: Data
        switch error {
        case "operationOutcomeUnknown":
            outcome = .failed(.operationOutcomeUnknown(reportedOperation))
            key = "id"; identity = try JSONEncoder().encode(operation)
        case "guestNotReachable":
            outcome = .failed(.guestNotReachable(reportedEnvironment))
            key = "environmentID"; identity = try JSONEncoder().encode(environment)
        default:
            outcome = .failed(.hostKeyChanged(reportedEnvironment))
            key = "environmentID"; identity = try JSONEncoder().encode(environment)
        }
        let fields = ["\"" + key + "\":" + String(decoding: identity, as: UTF8.self),
                      "\"outcome\":" + String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)]
        let ordered = outcomeFirst ? Array(fields.reversed()) : fields
        let tail = Data(("{" + ordered.joined(separator: ",")).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(tail) }
        // The conflicting UUID is already impossible before its closing quote/braces.
        let lastQuote = try #require(tail.lastIndex(of: 34))
        #expect(throws: StateStoreError.corruptJournal(line: 1)) {
            try JournalReplayChunk(Data(tail.prefix(upTo: lastQuote)))
        }
        let consistent = Data(String(decoding: tail, as: UTF8.self)
            .replacingOccurrences(of: different.uuidString, with: original.uuidString).utf8)
        for length in 1...consistent.count {
            #expect(try JournalReplayChunk(Data(consistent.prefix(length))).truncatedTail)
        }
    }

    @Test func outcomeShapesRetainUUIDAndNumericPayloadPrefixes() throws {
        let id = OperationID(), environment = EnvironmentID()
        let outcomes: [JournalRecord.Outcome] = [
            .completed, .unknown, .notApplied, .failed(.canceled),
            .failed(.operationOutcomeUnknown(id)), .failed(.guestNotReachable(environment)),
            .failed(.hostKeyChanged(environment)), .failed(.insufficientDisk(requiredBytes: .max, availableBytes: 0)),
            .failed(.unsupportedHost(.insufficientMemory(foundBytes: 0, minimumBytes: .max))),
            .failed(.protocolMismatch(client: .min, service: .max)), .failed(.vmSlotUnavailable(maximum: .max)),
            .failed(.invalidRequest(.malformed)), .failed(.downloadVerificationFailed(check: .signature)),
            .failed(.credentialsLocked(.hostKeychain)), .failed(.loginExpired(.codex)),
            .failed(.toolMismatch(tool: .vmRuntime)), .failed(.runtimeMissing)
        ]
        for outcome in outcomes {
            try checkEveryCut(JournalRecord(id: id, environmentID: environment, operation: .startEnvironment,
                                          timestamp: Date(timeIntervalSinceReferenceDate: 1e-20), outcome: outcome))
        }
        for stage in ProvisioningStage.allCases {
            try checkEveryCut(JournalRecord(id: id, environmentID: environment, operation: .provision(stage: stage),
                                          timestamp: Date(), outcome: .checkpoint(stage)))
        }
    }

    private func checkEveryCut(_ record: JournalRecord) throws {
        for sorted in [false, true] {
            let encoder = JSONEncoder()
            if sorted { encoder.outputFormatting = [.sortedKeys] }
            let bytes = try encoder.encode(record)
            for length in 1..<bytes.count {
                let chunk = try JournalReplayChunk(Data(bytes.prefix(length)))
                #expect(chunk.truncatedTail)
                #expect(chunk.validatedByteCount == 0 && chunk.history.records.isEmpty)
            }
        }
    }

    @Test(arguments: [1.001, -1.001, 1e20, 1e-20, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude,
                      792938037.3147308, -792938037.3147308, -9.084938291167941e+48,
                      Double(792938037.3147308).nextDown, Double(792938037.3147308).nextUp])
    func canonicalDateCutsRemainRecoverable(value: Double) throws {
        try checkEveryCut(JournalRecord(id: OperationID(), environmentID: EnvironmentID(),
                                       operation: .startEnvironment,
                                       timestamp: Date(timeIntervalSinceReferenceDate: value), outcome: .started))
    }

    @Test(arguments: ["1.00,", "1E+20", "1e+020", "-0.00,", "01", "+1", "1e999", "1.00e-2"])
    func noncanonicalDateTokensCannotGrantRepair(token: String) {
        let tail = Data(("{\"timestamp\":" + token).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(tail) }
    }

    @Test func fractionalEOFIsNotProofThatTheNumberWasComplete() throws {
        // These bytes can come from a genuine interruption while encoding 1.001.
        #expect(try JournalReplayChunk(Data("{\"timestamp\":1.00".utf8)).truncatedTail)
    }

    @Test func interruptedDateCanRequireADigitOtherThanZeroOrOne() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 792938037.3147308)
        let encoded = String(decoding: try JSONEncoder().encode(timestamp), as: UTF8.self)
        let prefix = "792938037.314730"
        try #require(encoded.hasPrefix(prefix) && encoded.count > prefix.count)
        let chunk = try JournalReplayChunk(Data(("{\"timestamp\":" + prefix).utf8))
        #expect(chunk.truncatedTail)
        #expect(chunk.validatedByteCount == 0 && chunk.history.records.isEmpty)
    }

    @Test func interruptedDateBeforeExponentMarkerHasAnEncoderWitness() throws {
        let encoded = String(decoding: try JSONEncoder().encode(
            Date(timeIntervalSinceReferenceDate: -9.084938291167941e+48)), as: UTF8.self)
        let exponent = try #require(encoded.firstIndex(of: "e"))
        let mantissa = String(encoded[..<exponent])
        #expect(JournalTailPrefix.accepts(Data(("{\"timestamp\":" + mantissa).utf8)))
    }

    @Test(arguments: ["id", "environmentID"])
    func lowercaseIdentityRemainsCorruption(key: String) throws {
        let uuid = UUID(uuidString: "ABCDEF12-ABCD-ABCD-ABCD-ABCDEF123456")!
        let canonical = String(decoding: try JSONEncoder().encode(uuid), as: UTF8.self)
        try #require(canonical == "\"ABCDEF12-ABCD-ABCD-ABCD-ABCDEF123456\"")
        let tail = Data(("{\"" + key + "\":" + canonical.lowercased()).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(tail) }
        #expect(try JournalReplayChunk(Data(("{\"" + key + "\":" + canonical).utf8)).truncatedTail)
    }

    @Test(arguments: [
        "not json", "{]", " ", "{\"unknown", "{\"format\":3", "{\"format\":\"",
        "{\"id\":\"not-a-uuid", "{\"operation\":{\"invented", "{\"timestamp\":01",
        "{\"timestamp\":1e+x", "{\"format\":2,\"format", "{\"outcome\":[",
        "{\"outcome\":{\"failed\":{\"_0\":{\"vmSlotUnavailable\":{\"maximum\":9223372036854775808",
        "{\"id\":\"\\q", "{\"format\":2,}", "{}garbage"
    ])
    func impossibleUnterminatedBytesDoNotGrantTruncation(tail: String) throws {
        let start = JournalRecord(id: OperationID(), environmentID: EnvironmentID(), operation: .startEnvironment,
                                  timestamp: Date(), outcome: .started)
        var bytes = try JSONEncoder().encode(start)
        bytes.append(10)
        let prefix = try JournalReplayChunk(bytes)
        #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try JournalReplayChunk(Data(tail.utf8), following: prefix.history)
        }
        #expect(prefix.history.inFlight[start.id] == start)
    }

    @Test(arguments: [Data([123, 0]), Data([123, 34, 0xff]), Data([123, 34, 0xc3])])
    func invalidUTF8AndNULRemainEvidence(bytes: Data) {
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(bytes) }
    }

    @Test(arguments: [UInt8(9), 13, 32])
    func nonEncoderWhitespaceCannotReplaceMissingBytes(whitespace: UInt8) throws {
        let record = JournalRecord(id: OperationID(), environmentID: EnvironmentID(), operation: .startEnvironment,
                                   timestamp: Date(), outcome: .started)
        let encoded = try JSONEncoder().encode(record)
        for damaged in [Data([123, whitespace]), Data(encoded.dropLast()) + Data([whitespace]),
                        Data([123, whitespace]) + Data(encoded.dropFirst().dropLast())] {
            #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(damaged) }
        }
    }
}
