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
}
