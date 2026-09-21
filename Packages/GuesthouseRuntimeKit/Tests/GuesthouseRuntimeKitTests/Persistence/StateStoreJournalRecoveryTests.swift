import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

/// Retained #57 final-record/recovery cases at the runtime-owned public transaction boundary.
@Suite(.timeLimit(.minutes(1))) struct StateStoreJournalRecoveryTests {
    @Test func failedOutcomeWritePreservesEvidenceAndRequiresInspection() async throws {
        let fixture = try Fixture(), original = try await fixture.open(), started = Self.record()
        try await original.append(started)
        let before = try fixture.bytes(), cause = StateStoreError.fileUnwritable(name: .stateDirectory)
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { _, _ in throw cause }))
        let completed = Self.record(id: started.id, environment: started.environmentID, outcome: .completed)
        let expected = StateStoreError.journalWriteUncertain(cause: cause)
        await #expect(throws: expected) { try await store.append(completed) }
        #expect(expected.recoveryActions.first == .inspectState)
        let evidence = try fixture.bytes()
        #expect(evidence.starts(with: before) && evidence.count > before.count)
        let reopened = try await fixture.open(), replay = try await reopened.replay()
        #expect(replay.records == [started, completed] && !replay.truncatedTail)
        #expect(try fixture.bytes() == evidence)
        // Visible terminal evidence does not retroactively turn the refused save into success.
    }

    @Test func unencodableOutcomeLeavesTheAcceptedStartUnchanged() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        try await store.append(started)
        let evidence = try fixture.bytes()
        let invalid = JournalRecord(id: started.id, environmentID: started.environmentID, operation: started.operation,
                                    timestamp: Date(timeIntervalSinceReferenceDate: .infinity), outcome: .completed)
        await #expect(throws: StateStoreError.unencodable(name: .journal)) { try await store.append(invalid) }
        #expect(try fixture.bytes() == evidence)
        #expect(try await store.replay().inFlight[started.id] == started)
    }

    @Test func failedPermissionBarrierKeepsJournalUnreadDespiteVisibleRepair() async throws {
        let fixture = try Fixture(), original = try await fixture.open(), started = Self.record()
        try await original.append(started)
        let evidence = try fixture.bytes(), barriers = Mutex(0), writes = Mutex(0)
        try #require(chmod(fixture.journal.path, 0o666) == 0)
        let failure = StateStoreError.fileUnwritable(name: .journal)
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { fd, name in
            let metadata = try StateFileProtection.verify(fd, kind: .regularFile)
            #expect(metadata.st_mode & 0o777 == 0o600 && name == .journal)
            let attempt = barriers.withLock { value in value += 1; return value }
            if attempt == 1 { throw failure }
            try StateFileIO.fullySynchronize(fd, name: name)
        }, journalWrite: { fd, bytes in
            writes.withLock { $0 += 1 }
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }))
        let settled = Self.record(id: started.id, environment: started.environmentID, outcome: .notApplied)
        await #expect(throws: failure) { try await store.append(settled) }
        #expect(barriers.withLock { $0 } == 1 && writes.withLock { $0 } == 0)
        #expect(try fixture.bytes() == evidence)
        // Repaired metadata is not evidence that unread operation bytes stayed unchanged.
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.append(settled) }
        #expect(barriers.withLock { $0 } == 1 && writes.withLock { $0 } == 0)
        #expect(try fixture.bytes() == evidence)
    }

    @Test(arguments: [StateFileAccess.readSnapshot, .readJournal])
    func failedReadRepairDoesNotClearUnreadJournalEvidence(access: StateFileAccess) async throws {
        let fixture = try Fixture(), original = try await fixture.open(), started = Self.record()
        try await Self.prepareReadFixture(access, store: original, record: started)
        let file = fixture.state.appending(path: access.name), evidence = try Data(contentsOf: file)
        try #require(chmod(file.path, 0o666) == 0)
        try fixture.grantReadACL(file)
        let barriers = Mutex(0), failure = StateStoreError.fileUnwritable(name: access.label)
        let store = try await fixture.open(hooks: StateStoreHooks(permission: { fd, name in
            let info = try StateFileProtection.verify(fd, kind: .regularFile)
            #expect(name == access.label && info.st_mode & 0o777 == 0o600)
            let attempt = barriers.withLock { value in value += 1; return value }
            if attempt == 1 { throw failure }
            try StateFileIO.fullySynchronize(fd, name: name)
        }))
        await #expect(throws: failure) { try await Self.readFixture(access, store: store, record: started) }
        #expect(barriers.withLock { $0 } == 1)
        if access == .readJournal {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await Self.readFixture(access, store: store, record: started)
            }
        } else {
            try await Self.readFixture(access, store: store, record: started)
        }
        #expect(barriers.withLock { $0 } == (access == .readJournal ? 1 : 2))
        #expect(try Data(contentsOf: file) == evidence)
    }

    @Test func stateDirectoryReattachmentAfterBarrierRefusesBegin() async throws {
        let fixture = try Fixture()
        let store = try await fixture.open(hooks: StateStoreHooks(directory: { fd, name in
            try StateFileIO.fullySynchronize(fd, name: name)
            try fixture.reattachStateDirectory()
        }))
        // The peer must overlap this poisoned lease, not open after its last owner disappears.
        defer { withExtendedLifetime(store) {} }
        let expected = StateStoreError.journalWriteUncertain(cause: .insecureDirectory(reason: .changed))
        await #expect(throws: expected) { try await store.begin(.startEnvironment, for: EnvironmentID()) }
        let evidence = try fixture.bytes()
        for _ in 0..<2 {
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await store.replay() }
            await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
                try await store.begin(.startEnvironment, for: EnvironmentID())
            }
            #expect(try fixture.bytes() == evidence)
        }
        // Pure decoding can describe retained bytes, not clear shared binding uncertainty.
        let reopened = try await fixture.open(), records = try JournalReplayChunk(evidence).history.records
        let started = try #require(records.first)
        #expect(records.count == 1 && started.outcome == .started)
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) { try await reopened.replay() }
        await #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
            try await reopened.begin(.startEnvironment, for: started.environmentID)
        }
        #expect(try fixture.bytes() == evidence)
    }

    @Test(arguments: [
        Contradiction.orphanedOutcome, .duplicateStart, .concurrentStart, .changedEnvironment,
        .changedOperation, .outcomeAfterSettlement, .conflictingFailureIdentity,
    ])
    func completeContradictoryFinalRecordsAreNeverTruncated(contradiction: Contradiction) async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let (prefix, final) = Self.records(for: contradiction)
        var original = Data()
        for record in prefix {
            original.append(try JSONEncoder().encode(record))
            original.append(0x0A)
        }
        let finalBytes = try JSONEncoder().encode(final)
        if case .conflictingFailureIdentity = contradiction {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: finalBytes) }
        } else {
            try #require(try JSONDecoder().decode(JournalRecord.self, from: finalBytes) == final)
        }
        original.append(finalBytes) // Complete JSON, deliberately no final separator.
        try fixture.write(original)
        let failure = StateStoreError.corruptJournal(line: prefix.count + 1)
        await #expect(throws: failure) { try await store.replay() }
        await #expect(throws: failure) { try await store.begin(.exportWork, for: EnvironmentID()) }
        #expect(try fixture.bytes() == original)
        await #expect(throws: failure) { try await store.replay() }
    }

    @Test(arguments: [
        SelfContradiction.operationIdentity, .checkpointStage, .guestEnvironment, .hostKeyEnvironment,
    ], [false, true])
    func restoredRecordsMustMeetTheSameRulesAsAppend(contradiction: SelfContradiction, terminated: Bool) async throws {
        let fixture = try Fixture(), store = try await fixture.open()
        let started = Self.record(operation: .provision(stage: .sshPaired))
        let outcome: JournalRecord.Outcome = switch contradiction {
        case .operationIdentity: .failed(.operationOutcomeUnknown(OperationID()))
        case .checkpointStage: .checkpoint(.guestSecured)
        case .guestEnvironment: .failed(.guestNotReachable(EnvironmentID()))
        case .hostKeyEnvironment: .failed(.hostKeyChanged(EnvironmentID()))
        }
        let inconsistent = Self.record(id: started.id, environment: started.environmentID,
                                       operation: started.operation, outcome: outcome)
        let line = try JSONEncoder().encode(inconsistent)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: line) }
        try await store.append(started)
        let evidence = try fixture.bytes()
        await #expect(throws: StateStoreError.inconsistentRecord(started.id)) { try await store.append(inconsistent) }
        #expect(try fixture.bytes() == evidence)
        #expect(try await store.replay().records == [started])

        // A restored, syntactically valid record must not bypass append's identity checks.
        let restored = evidence + line + (terminated ? Data([0x0A]) : Data())
        try fixture.write(restored)
        let reopened = try await fixture.open()
        let failure = StateStoreError.corruptJournal(line: 2)
        await #expect(throws: failure) { try await reopened.replay() }
        await #expect(throws: failure) { try await reopened.begin(.exportWork, for: EnvironmentID()) }
        #expect(try fixture.bytes() == restored)
        // Nor may the already-open store retain its formerly valid cached prefix.
        await #expect(throws: failure) { try await store.replay() }
        #expect(try fixture.bytes() == restored)
    }

    @Test(arguments: [
        (0, StateStoreError.corruptJournal(line: 1)), (-1, .corruptJournal(line: 1)),
        (1, .unsupportedJournalFormat(line: 1, format: 1)),
        (99, .unsupportedJournalFormat(line: 1, format: 99)),
    ])
    func completeFinalFormatsRetainTheirDistinctFailures(format: Int, failure: StateStoreError) async throws {
        let fixture = try Fixture(), store = try await fixture.open(), record = Self.record()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        try #require(object["format"] as? Int == 2) // The migrated format, not the prototype's 1.
        object["format"] = format
        let original = try JSONSerialization.data(withJSONObject: object)
        try fixture.write(original)
        await #expect(throws: failure) { try await store.replay() }
        await #expect(throws: failure) { try await store.begin(.exportWork, for: EnvironmentID()) }
        #expect(try fixture.bytes() == original)
    }

    @Test(arguments: ["id", "operation"])
    func completeFinalValuesWithUndecodableFieldsArePreserved(field: String) async throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.record())) as? [String: Any])
        object[field] = "invalid-fixture-value"
        try await Self.requireCompleteValueRefused(JSONSerialization.data(withJSONObject: object))
    }

    @Test(arguments: ["{}", "[]", "null", "false", "\"not a record\""])
    func completeNonrecordJSONCannotBeTreatedAsAnInterruptedWrite(raw: String) async throws {
        try await Self.requireCompleteValueRefused(Data(raw.utf8))
    }

    @Test func incompleteOutcomePreservesTheStartUntilAnInspectedSettlement() async throws {
        let fixture = try Fixture(), store = try await fixture.open(), started = Self.record()
        let completed = Self.record(id: started.id, environment: started.environmentID, outcome: .completed)
        let prefix = try JSONEncoder().encode(started) + Data([0x0A])
        let complete = try JSONEncoder().encode(completed)
        let original = prefix + complete.dropLast()
        try fixture.write(original)
        let replay = try await store.replay()
        #expect(replay.truncatedTail && replay.records == [started] && replay.inFlight[started.id] == started)
        await #expect(throws: StateStoreError.operationUnresolved(started.id)) {
            try await store.begin(.stopEnvironment, for: started.environmentID)
        }
        #expect(try fixture.bytes() == original)
        try await store.append(completed)
        let settled = try await store.replay()
        #expect(settled.records == [started, completed] && settled.inFlight.isEmpty && !settled.truncatedTail)
    }

    enum Contradiction: Sendable {
        case orphanedOutcome, duplicateStart, concurrentStart, changedEnvironment
        case changedOperation, outcomeAfterSettlement, conflictingFailureIdentity
    }

    enum SelfContradiction: Sendable {
        case operationIdentity, checkpointStage, guestEnvironment, hostKeyEnvironment
    }

    // This constructs invalid fixtures; the assertion is always the same refusal/preservation.
    private static func records(for contradiction: Contradiction) -> ([JournalRecord], JournalRecord) {
        let started = record(), id = started.id, environment = started.environmentID
        let completed = record(id: id, environment: environment, outcome: .completed)
        switch contradiction {
        case .orphanedOutcome: return ([], completed)
        case .duplicateStart: return ([started], started)
        case .concurrentStart: return ([started], record(environment: environment))
        case .changedEnvironment: return ([started], record(id: id, outcome: .completed))
        case .changedOperation:
            return ([started], record(id: id, environment: environment, operation: .stopEnvironment, outcome: .completed))
        case .outcomeAfterSettlement: return ([started, completed], record(id: id, environment: environment, outcome: .unknown))
        case .conflictingFailureIdentity:
            return ([started], record(id: id, environment: environment, outcome: .failed(.operationOutcomeUnknown(OperationID()))))
        }
    }

    private static func requireCompleteValueRefused(_ original: Data) async throws {
        _ = try JSONSerialization.jsonObject(with: original, options: .fragmentsAllowed)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(JournalRecord.self, from: original) }
        let fixture = try Fixture(), store = try await fixture.open()
        try fixture.write(original)
        let failure = StateStoreError.corruptJournal(line: 1)
        await #expect(throws: failure) { try await store.replay() }
        await #expect(throws: failure) { try await store.begin(.exportWork, for: EnvironmentID()) }
        #expect(try fixture.bytes() == original)
    }

    private static func prepareReadFixture(_ access: StateFileAccess, store: StateStore, record: JournalRecord) async throws {
        switch access {
        case .readSnapshot: try await store.saveSnapshot(.empty)
        case .readJournal: try await store.append(record)
        case .writeJournal: Issue.record("This fixture only covers read operations")
        }
    }

    private static func readFixture(_ access: StateFileAccess, store: StateStore, record: JournalRecord) async throws {
        switch access {
        case .readSnapshot: #expect(try await store.loadSnapshot() == .empty)
        case .readJournal: #expect(try await store.replay().records == [record])
        case .writeJournal: Issue.record("This fixture only covers read operations")
        }
    }

    private static func record(
        id: OperationID = OperationID(), environment: EnvironmentID = EnvironmentID(),
        operation: JournalOperation = .startEnvironment, outcome: JournalRecord.Outcome = .started
    ) -> JournalRecord {
        JournalRecord(id: id, environmentID: environment, operation: operation,
                      timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000), outcome: outcome)
    }

    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var journal: URL { state.appending(path: "journal.ndjson") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-journal-recovery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
        func open(hooks: StateStoreHooks = StateStoreHooks()) async throws -> StateStore {
            try await StateStore.open(storage: { try RuntimeStorage(root: self.root) }, hooks: hooks)
        }
        func write(_ bytes: Data) throws {
            let fd = Darwin.open(journal.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try #require(fd >= 0)
            defer { close(fd) }
            try #require(fchmod(fd, 0o600) == 0)
            try StateFileIO.writeAll(fd, bytes, name: .journal)
        }
        func bytes() throws -> Data { try Data(contentsOf: journal) }
        func grantReadACL(_ file: URL) throws {
            let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            try #require(fd >= 0)
            defer { close(fd) }
            var acl: acl_t? = acl_init(1)
            defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
            var entry: acl_entry_t?
            try #require(acl_create_entry(&acl, &entry) == 0)
            let created = try #require(entry)
            try #require(acl_set_tag_type(created, ACL_EXTENDED_ALLOW) == 0)
            var qualifier = try #require(UUID(uuidString: String(format: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA%08X", getuid()))).uuid
            try #require(withUnsafePointer(to: &qualifier) { acl_set_qualifier(created, UnsafeRawPointer($0)) } == 0)
            var permissions: acl_permset_t?
            try #require(acl_get_permset(created, &permissions) == 0)
            let permissionSet = try #require(permissions), granted = try #require(acl)
            try #require(acl_add_perm(permissionSet, ACL_READ_DATA) == 0)
            try #require(acl_set_fd(fd, granted) == 0)
            // Prove the setup really has an ACL entry, not merely a permissive mode.
            let observed = try #require(acl_get_fd(fd))
            defer { acl_free(UnsafeMutableRawPointer(observed)) }
            var observedEntry: acl_entry_t?
            try #require(acl_get_entry(observed, ACL_FIRST_ENTRY.rawValue, &observedEntry) == 0)
            try #require(observedEntry != nil)
        }
        func reattachStateDirectory() throws {
            let detached = root.appending(path: "detached-state")
            var before = stat()
            try #require(lstat(state.path, &before) == 0)
            try #require(rename(state.path, detached.path) == 0)
            let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try #require(fd >= 0)
            defer { close(fd) }
            try StateFileIO.fullySynchronize(fd, name: .stateDirectory)
            try #require(rename(detached.path, state.path) == 0)
            var after = stat()
            try #require(lstat(state.path, &after) == 0)
            try #require(StateFileIdentity(before) == StateFileIdentity(after))
            try #require(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                         && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            try #require(StateFileVersion(before) != StateFileVersion(after))
        }
        deinit { try? FileManager.default.removeItem(at: base) }
    }
}
