import Foundation
import GuesthouseCore
import Testing

@Suite struct JournalReplayChunkTests {
    let id = OperationID()
    let environment = EnvironmentID()

    func record(_ outcome: JournalRecord.Outcome, id: OperationID? = nil,
                environment: EnvironmentID? = nil, operation: JournalOperation = .startEnvironment) -> JournalRecord {
        JournalRecord(id: id ?? self.id, environmentID: environment ?? self.environment,
                      operation: operation, timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000), outcome: outcome)
    }

    func line(_ record: JournalRecord, terminated: Bool = true) throws -> Data {
        var bytes = try JSONEncoder().encode(record)
        if terminated { bytes.append(0x0A) }
        return bytes
    }

    @Test func emptyInputAddsNoRecordOrBytes() throws {
        let chunk = try JournalReplayChunk(Data())
        #expect(chunk.history.records.isEmpty)
        #expect(chunk.history.inFlight.isEmpty)
        #expect(chunk.validatedByteCount == 0)
        #expect(!chunk.truncatedTail)
        #expect(!chunk.unterminatedRecord)
    }

    @Test func completeLinesPreserveOrderingAndSettlement() throws {
        let start = record(.started)
        let lost = record(.unknown)
        let absent = record(.notApplied)
        let data = try line(start) + line(lost) + line(absent)
        let chunk = try JournalReplayChunk(data)
        #expect(chunk.history.records == [start, lost, absent])
        #expect(chunk.history.inFlight.isEmpty)
        #expect(chunk.validatedByteCount == data.count)
        #expect(!chunk.truncatedTail)
        #expect(!chunk.unterminatedRecord)
    }

    @Test func aChunkContinuesHistoryButCountsOnlyItsOwnBytes() throws {
        let start = record(.started)
        let first = try JournalReplayChunk(line(start))
        let data = try line(record(.unknown))
        let second = try JournalReplayChunk(data, following: first.history)
        #expect(second.history.records == [start, record(.unknown)])
        #expect(second.history.inFlight[id]?.outcome == .unknown)
        #expect(second.validatedByteCount == data.count)
        #expect(first.history.records == [start])
    }

    @Test func aCompleteFinalStartWithoutANewlineStillBlocksBlindRetry() throws {
        let start = record(.started)
        let bytes = try line(start, terminated: false)
        let chunk = try JournalReplayChunk(bytes)
        #expect(chunk.history.records == [start])
        #expect(chunk.history.inFlight == [id: start])
        #expect(chunk.validatedByteCount == bytes.count)
        #expect(!chunk.truncatedTail)
        #expect(chunk.unterminatedRecord)
        #expect(throws: StateStoreError.operationUnresolved(id)) {
            try chunk.history.validateAppend(record(.started, id: OperationID()))
        }
    }

    @Test func aTornTailDoesNotAdvanceTheValidatedOffset() throws {
        let start = record(.started)
        let prefix = try line(start)
        let final = try line(record(.completed), terminated: false)
        let bytes = prefix + final.dropLast()
        let chunk = try JournalReplayChunk(bytes)
        #expect(chunk.history.records == [start])
        #expect(chunk.history.inFlight == [id: start])
        #expect(chunk.validatedByteCount == prefix.count)
        #expect(chunk.truncatedTail)
        #expect(!chunk.unterminatedRecord)
        // The later read supplies the entire formerly torn line, not just its last byte.
        let repaired = try JournalReplayChunk(final, following: chunk.history)
        #expect(repaired.history.records == [start, record(.completed)])
        #expect(repaired.history.inFlight.isEmpty)
        #expect(repaired.validatedByteCount == final.count)
        #expect(repaired.unterminatedRecord)
        #expect(!repaired.truncatedTail)
    }

    @Test(arguments: ["", "not json", "{}", "[]", "null", "false"])
    func anEmptyOrMalformedCompleteLineIsNeverSkipped(json: String) throws {
        let prefix = try JournalReplayChunk(line(record(.started)))
        #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try JournalReplayChunk(Data((json + "\n").utf8), following: prefix.history)
        }
        #expect(prefix.history.records.count == 1)
    }

    @Test(arguments: ["{}", "[]", "null", "false", "\"not a record\"", "42"], [false, true])
    func completeInvalidJSONIsNotATornTail(json: String, terminated: Bool) {
        let data = Data((json + (terminated ? "\n" : "")).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(data) }
    }

    @Test(arguments: [1, 3, 99], [false, true])
    func unsupportedPositiveFormatsArePreservedAsUnsupported(format: Int, terminated: Bool) throws {
        let first = try JournalReplayChunk(line(record(.started)))
        let data = Data(("{\"format\":\(format)}" + (terminated ? "\n" : "")).utf8)
        #expect(throws: StateStoreError.unsupportedJournalFormat(line: 2, format: format)) {
            try JournalReplayChunk(data, following: first.history)
        }
        #expect(first.history.records == [record(.started)])
    }

    @Test(arguments: ["0", "-1", "true", "false", "null", "\"2\"", "2.5", "9223372036854775808"], [false, true])
    func malformedFormatsAreDamageNotAnUpgradeRequest(format: String, terminated: Bool) {
        let data = Data(("{\"format\":\(format)}" + (terminated ? "\n" : "")).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(data) }
    }

    @Test(arguments: ["id", "environmentID", "operation", "outcome"], [false, true])
    func aCompleteRecordWithAnInvalidFieldIsNotATornTail(field: String, terminated: Bool) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record(.started))) as? [String: Any])
        object[field] = "test-only-invalid-field"
        var bytes = try JSONSerialization.data(withJSONObject: object)
        if terminated { bytes.append(0x0A) }
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(bytes) }
    }

    enum Contradiction: Sendable {
        case orphanedOutcome, duplicateStart, concurrentStart, changedEnvironment
        case changedOperation, outcomeAfterSettlement, conflictingFailureIdentity
    }

    @Test(arguments: [Contradiction.orphanedOutcome, .duplicateStart, .concurrentStart, .changedEnvironment,
                      .changedOperation, .outcomeAfterSettlement, .conflictingFailureIdentity], [false, true])
    func completeContradictionsFailWithOrWithoutANewline(contradiction: Contradiction, terminated: Bool) throws {
        let start = record(.started)
        let completed = record(.completed)
        let prefix: [JournalRecord]
        let final: JournalRecord
        switch contradiction {
        case .orphanedOutcome: prefix = []; final = completed
        case .duplicateStart: prefix = [start]; final = start
        case .concurrentStart: prefix = [start]; final = record(.started, id: OperationID())
        case .changedEnvironment: prefix = [start]; final = record(.completed, environment: EnvironmentID())
        case .changedOperation: prefix = [start]; final = record(.completed, operation: .stopEnvironment)
        case .outcomeAfterSettlement: prefix = [start, completed]; final = record(.unknown)
        case .conflictingFailureIdentity: prefix = [start]; final = record(.failed(.operationOutcomeUnknown(OperationID())))
        }
        let bytes = try prefix.reduce(into: Data()) { $0.append(try line($1)) } + line(final, terminated: terminated)
        #expect(throws: StateStoreError.corruptJournal(line: prefix.count + 1)) { try JournalReplayChunk(bytes) }
    }

    @Test func aLateFailureCannotPublishAnEarlierNewPrefix() throws {
        let first = try JournalReplayChunk(line(record(.started)))
        let other = record(.started, id: OperationID(), environment: EnvironmentID())
        let bytes = try line(other) + Data("{}".utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 3)) {
            try JournalReplayChunk(bytes, following: first.history)
        }
        var retained = first.history
        try retained.append(other)
        #expect(retained.records.count == 2)
        #expect(first.history.records == [record(.started)])
    }

    @Test(arguments: [#""format":3"#, #""format":2"#, #""for\u006dat":3"#], [false, true])
    func duplicateFormatKeysRefuseEitherOrder(member: String, terminated: Bool) throws {
        let start = record(.started)
        let prefix = try JournalReplayChunk(line(start))
        let encoded = try #require(String(data: line(record(.completed), terminated: false), encoding: .utf8))
        for json in ["{" + member + "," + encoded.dropFirst(), encoded.dropLast() + "," + member + "}"] {
            let data = Data((json + (terminated ? "\n" : "")).utf8)
            #expect(throws: StateStoreError.corruptJournal(line: 2)) {
                try JournalReplayChunk(data, following: prefix.history)
            }
            #expect(prefix.history.records == [start])
            #expect(prefix.history.inFlight == [id: start])
        }
    }

    @Test(arguments: ["id", "environmentID", "operation", "outcome", "timestamp", #"\u0069d"#], [false, true])
    func duplicateRecoveryMembersCannotChooseAnOutcome(key: String, terminated: Bool) throws {
        let start = record(.started), completed = record(.completed)
        let prefix = try JournalReplayChunk(line(start))
        let encoded = try #require(String(data: line(completed, terminated: false), encoding: .utf8))
        let duplicate = ",\"" + key + "\":null}"
        let bytes = Data((encoded.dropLast() + duplicate + (terminated ? "\n" : "")).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try JournalReplayChunk(bytes, following: prefix.history)
        }
        #expect(prefix.history.inFlight == [id: start])
    }

    @Test(arguments: [false, true], [false, true])
    func ignoredUnrepresentableNumbersCannotBypassDuplicateKeys(duplicateFirst: Bool, terminated: Bool) throws {
        let start = record(.started), prefix = try JournalReplayChunk(line(start))
        let encoded = String(decoding: try line(record(.completed), terminated: false), as: UTF8.self)
        let extra = #""extension":1e9999,"outcome":{"unknown":{}}"#
        let json = duplicateFirst ? "{" + extra + "," + encoded.dropFirst()
            : encoded.dropLast() + "," + extra + "}"
        let bytes = Data((json + (terminated ? "\n" : "")).utf8)
        #expect(throws: StateStoreError.corruptJournal(line: 2)) {
            try JournalReplayChunk(bytes, following: prefix.history)
        }
        #expect(prefix.history.inFlight == [id: start])
    }

    @Test func ignoredUnrepresentableNumberWithoutDuplicatesRemainsForwardCompatible() throws {
        let start = record(.started)
        let encoded = String(decoding: try line(start, terminated: false), as: UTF8.self)
        let bytes = Data((encoded.dropLast() + #","extension":1e9999}"#).utf8)
        #expect(try JournalReplayChunk(bytes).history.records == [start])
    }

    @Test func nestedAndQuotedFormatKeysDoNotShadowTheEnvelope() throws {
        let start = record(.started)
        let encoded = try #require(String(data: line(start, terminated: false), encoding: .utf8))
        let extra = #", "extension":{"format":3,"nested":{"format":99}}, "text":"\"format\":3"}"#
        let chunk = try JournalReplayChunk(Data((encoded.dropLast() + extra).utf8))
        #expect(chunk.history.records == [start])
        #expect(chunk.unterminatedRecord)
    }

    @Test func ignoredRawFieldsCannotBeReencodedFromTheReplay() throws {
        let start = record(.started)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(start)) as? [String: Any])
        object["rawOutput"] = "test-only-discarded-output"
        let chunk = try JournalReplayChunk(JSONSerialization.data(withJSONObject: object))
        #expect(chunk.history.records == [start])
        let encoded = try JSONEncoder().encode(try #require(chunk.history.records.first))
        let restored = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(restored.keys) == ["format", "id", "environmentID", "operation", "timestamp", "outcome"])
    }

    @Test(arguments: [false, true])
    func nestedRecoveryDuplicatesCannotSelectSettlement(terminated: Bool) throws {
        let start = record(.started), prefix = try JournalReplayChunk(line(start))
        let identity = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        let environment = String(decoding: try JSONEncoder().encode(self.environment), as: UTF8.self)
        let other = String(decoding: try JSONEncoder().encode(EnvironmentID()), as: UTF8.self)
        let errors = [#"{"canceled":{}}"#, #"{"runtimeMissing":{}}"#]
        let members = [#""_0""#, #""\u005f0""#]
        for key in members {
            for pair in [(errors[0], errors[1]), (errors[1], errors[0])] {
                let outcome = "{\"failed\":{\"_0\":" + pair.0 + "," + key + ":" + pair.1 + "}}"
                try refuse(outcome)
            }
            for pair in [(environment, other), (other, environment)] {
                try refuse("{\"failed\":{\"_0\":{\"guestNotReachable\":{\"_0\":" + pair.0
                           + "," + key + ":" + pair.1 + "}}}}")
            }
        }
        func refuse(_ outcome: String) throws {
            let json = "{\"format\":2,\"id\":" + identity + ",\"environmentID\":" + environment
                + ",\"operation\":{\"startEnvironment\":{}},\"timestamp\":0,\"outcome\":" + outcome + "}"
            #expect(throws: StateStoreError.corruptJournal(line: 2)) {
                try JournalReplayChunk(Data((json + (terminated ? "\n" : "")).utf8), following: prefix.history)
            }
            #expect(prefix.history.inFlight[id] == start)
        }
    }

    @Test func nestedObjectsInArraysHaveSeparateMemberNamespaces() throws {
        let start = record(.started)
        let encoded = String(decoding: try line(start, terminated: false), as: UTF8.self)
        let valid = encoded.dropLast() + #", "extension":[{"same":1},{"same":2}], "text":"\"same\":3"}"#
        #expect(try JournalReplayChunk(Data(valid.utf8)).history.records == [start])
        let invalid = encoded.dropLast() + #", "extension":[{"same":1,"sa\u006de":2}]}"#
        #expect(throws: StateStoreError.corruptJournal(line: 1)) { try JournalReplayChunk(Data(invalid.utf8)) }
    }
}
