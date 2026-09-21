import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct StateStoreInspectionTests {
    @Test(arguments: [false, true]) func absentRootDoesNotPrepareAnyDirectories(nested: Bool) throws {
        let fixture = try Fixture()
        let root = nested ? fixture.base.appending(path: "missing/Guesthouse") : fixture.root
        #expect(try StateStore.inspectSnapshot(storage: { try RuntimeStorage.existing(root: root) }) == .empty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).isEmpty)
    }

    @Test func absentSnapshotDoesNotCreateFilesOrSynchronizeMetadata() throws {
        let fixture = try Fixture()
        _ = try RuntimeStorage(root: fixture.root)
        let before = try fixture.version(fixture.state)
        #expect(try fixture.inspect() == .empty)
        #expect(try fixture.version(fixture.state) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func rootAppearingAfterMissingObservationRefusesEmptyInventory(restore: Bool) throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let bytes = try Data(contentsOf: fixture.snapshot)
        let retained = fixture.base.appending(path: "retained")
        try FileManager.default.moveItem(at: fixture.root, to: retained)
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try StateStore.inspectSnapshot(storage: {
                try RuntimeStorage.existing(root: fixture.root, afterMissingRoot: {
                    if restore { try FileManager.default.moveItem(at: retained, to: fixture.root) }
                    else { try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false) }
                })
            })
        }
        let saved = restore ? fixture.snapshot : retained.appending(path: "state/environments.json")
        #expect(try Data(contentsOf: saved) == bytes)
    }

    @Test func linkAppearingAfterMissingRootIsNotFollowed() throws {
        let fixture = try Fixture()
        let absent = fixture.base.appending(path: "absent-target")
        #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
            try StateStore.inspectSnapshot(storage: {
                try RuntimeStorage.existing(root: fixture.root, afterMissingRoot: {
                    try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: absent)
                })
            })
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.root.path) == absent.path)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    @Test(arguments: ["observed", "verified", "opening", "state-opening"], [false, true])
    func observedDirectoryReplacementCannotSwitchInventory(phase: String, emptyReplacement: Bool) throws {
        let fixture = try Fixture()
        try fixture.prepare()
        #expect(try fixture.inspect() == .empty) // Unchanged-root control.
        let original = try Data(contentsOf: fixture.snapshot)
        let retained = fixture.base.appending(path: "retained-root")
        let stateOnly = phase == "state-opening"
        let replacement = fixture.base.appending(path: "replacement-root")
        _ = try RuntimeStorage(root: replacement)
        let replacementSnapshot = replacement.appending(path: "state/environments.json")
        let environment = DevelopmentEnvironment(name: "Replacement inventory")
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let otherBytes = try JSONEncoder().encode(EnvironmentsSnapshot(environments: [environment], slots: slots,
            provisioning: [environment.id: .initial]))
        if !emptyReplacement {
            try otherBytes.write(to: replacementSnapshot)
            try #require(chmod(replacementSnapshot.path, 0o600) == 0)
        }
        func replaceRoot() throws {
            let source = stateOnly ? fixture.state : fixture.root
            try FileManager.default.moveItem(at: source, to: retained)
            try FileManager.default.moveItem(at: stateOnly ? replacement.appending(path: "state") : replacement, to: source)
        }
        if phase.hasSuffix("opening") {
            let storage = try #require(RuntimeStorage.existing(root: fixture.root))
            #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
                try StateDirectoryAnchor(storage: storage, openDirectory: { path, flags in
                    do { try replaceRoot() }
                    catch { Issue.record("Fixture root replacement failed"); return -1 }
                    return open(path, flags)
                })
            }
            // The failed anchor is never returned. A new leaf discovery is a separate read;
            // root-bound storage alone does not retain a failed anchor's leaf observation.
            for _ in 0..<(stateOnly ? 0 : 2) {
                #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
                    try StateStore.inspectSnapshot(storage: { storage })
                }
            }
        } else {
            #expect(throws: StateStoreError.insecureDirectory(reason: .changed)) {
                try StateStore.inspectSnapshot(storage: {
                    let storage = try RuntimeStorage.existing(root: fixture.root, afterObservedRoot: {
                        if phase == "observed" { try replaceRoot() }
                    })
                    if phase == "verified" { try replaceRoot() }
                    return storage
                })
            }
        }
        #expect(try Data(contentsOf: retained.appending(path: stateOnly ? "environments.json" : "state/environments.json")) == original)
        if emptyReplacement { #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path)) }
        else { #expect(try Data(contentsOf: fixture.snapshot) == otherBytes) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).sorted()
                == (emptyReplacement ? [] : ["environments.json"]))
    }

    @Test(arguments: [mode_t(0), 0o200])
    func unreadableSnapshotModeRetainsPermissionGuidance(mode: mode_t) throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let bytes = try Data(contentsOf: fixture.snapshot)
        try #require(chmod(fixture.snapshot.path, mode) == 0)
        defer { _ = chmod(fixture.snapshot.path, 0o600) }
        let before = try fixture.version(fixture.snapshot)
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) { try fixture.inspect() }
        #expect(try fixture.version(fixture.snapshot) == before)
        try #require(chmod(fixture.snapshot.path, 0o600) == 0)
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
    }

    @Test func denyReadACLRetainsPermissionGuidanceWithoutRepair() async throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let bytes = try Data(contentsOf: fixture.snapshot)
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/chmod"),
            arguments: ["+a", "everyone deny read", fixture.snapshot.path], timeout: .seconds(5)))
        let report = try await run.waitForExit()
        try #require(try report.childExit?.get() == .status(0) && !report.timedOut && !report.canceled)
        let before = try fixture.version(fixture.snapshot)
        #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) { try fixture.inspect() }
        #expect(try fixture.version(fixture.snapshot) == before)
        // Only the fixture explicitly removes its own ACL after verifying inspection did not.
        let clear = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/chmod"),
            arguments: ["-N", fixture.snapshot.path], timeout: .seconds(5)))
        let cleared = try await clear.waitForExit()
        try #require(try cleared.childExit?.get() == .status(0) && !cleared.timedOut && !cleared.canceled)
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
    }

    @Test func persistedSnapshotIsReadWithoutPreparingAStoreAgain() async throws {
        let fixture = try Fixture()
        let environment = DevelopmentEnvironment(name: "Retained work")
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        let value = EnvironmentsSnapshot(environments: [environment], slots: slots,
                                         provisioning: [environment.id: .initial])
        let store = try await StateStore.open(storage: { try RuntimeStorage(root: fixture.root) })
        try await store.saveSnapshot(value)
        let before = try fixture.version(fixture.snapshot), bytes = try Data(contentsOf: fixture.snapshot)
        #expect(try fixture.inspect() == value)
        #expect(try fixture.version(fixture.snapshot) == before)
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
    }

    @Test(arguments: ["root", "state", "snapshot"], [false, true])
    func protectionDriftIsRefusedAndNeverRepaired(target: String, acl: Bool) async throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let url = target == "root" ? fixture.root : target == "state" ? fixture.state : fixture.snapshot
        if acl {
            let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/chmod"),
                arguments: ["+a", "everyone allow read", url.path], timeout: .seconds(5)))
            let report = try await run.waitForExit()
            try #require(try report.childExit?.get() == .status(0) && !report.timedOut && !report.canceled)
        } else { try #require(chmod(url.path, target == "snapshot" ? 0o640 : 0o750) == 0) }
        let before = try fixture.version(url), bytes = try Data(contentsOf: fixture.snapshot)
        #expect(throws: StateStoreError.self) { try fixture.inspect() }
        #expect(throws: StateStoreError.self) { try fixture.inspect() }
        #expect(try fixture.version(url) == before)
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
    }

    @Test func existingRootWithoutStateIsNotSilentlyReinitialized() throws {
        let fixture = try Fixture()
        _ = try RuntimeStorage(root: fixture.root)
        try FileManager.default.moveItem(at: fixture.state, to: fixture.base.appending(path: "preserved-state"))
        #expect(throws: StateStoreError.self) { try fixture.inspect() }
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
    }

    @Test(arguments: ["{", "{}", "{\"schemaVersion\":1}", "{\"schemaVersion\":2}", "{\"schemaVersion\":3}", "{\"schemaVersion\":99}"])
    func rejectedDocumentsKeepTheirBytesAndMetadata(raw: String) throws {
        let fixture = try Fixture()
        try fixture.prepare(bytes: Data(raw.utf8))
        let before = try fixture.version(fixture.snapshot)
        #expect(throws: StateStoreError.self) { try fixture.inspect() }
        #expect(try Data(contentsOf: fixture.snapshot) == Data(raw.utf8))
        #expect(try fixture.version(fixture.snapshot) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path) == ["environments.json"])
    }

    @Test(arguments: ["root", "state", "snapshot"], [false, true])
    func linkedLocationsAreNeverFollowed(target: String, dangling: Bool) throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let url = target == "root" ? fixture.root : target == "state" ? fixture.state : fixture.snapshot
        let retained = fixture.base.appending(path: "retained"), missing = fixture.base.appending(path: "missing")
        try FileManager.default.moveItem(at: url, to: retained)
        let destination = dangling ? missing : retained
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        #expect(throws: StateStoreError.self) { try fixture.inspect() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == destination.path)
        #expect(FileManager.default.fileExists(atPath: retained.path))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test(arguments: [false, true]) func nonregularOrMultiplyLinkedFilesAreRefused(pipe: Bool) throws {
        let fixture = try Fixture()
        _ = try RuntimeStorage(root: fixture.root)
        if pipe { try #require(mkfifo(fixture.snapshot.path, 0o600) == 0) }
        else {
            try fixture.write(Data("retained".utf8))
            try #require(link(fixture.snapshot.path, fixture.state.appending(path: "alias").path) == 0)
        }
        #expect(throws: StateStoreError.self) { try fixture.inspect() }
    }

    @Test func verifyOnlyAccessRetainsReadFlagsAndLockWithoutCallingABarrier() throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let storage = try #require(RuntimeStorage.existing(root: fixture.root))
        let anchor = try StateDirectoryAnchor(storage: storage)
        let before = try fixture.version(fixture.snapshot)
        let bytes = try anchor.withFile(.readSnapshot, protection: .verifyOnly,
            permissionBarrier: { _, _ in Issue.record("Read-only inspection invoked a write barrier") }) { fd in
                #expect(fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY)
                #expect(fcntl(fd, F_GETFL) & O_NONBLOCK != 0)
                #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
                let other = open(fixture.snapshot.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                try #require(other >= 0)
                defer { close(other) }
                #expect(flock(other, LOCK_EX | LOCK_NB) == -1)
                return try StateFileIO.readAll(fd, from: 0, name: .snapshot)
            }
        #expect(bytes == (try Data(contentsOf: fixture.snapshot)))
        #expect(try fixture.version(fixture.snapshot) == before)
    }

    @Test func verifyOnlyCannotCreateAJournal() throws {
        let fixture = try Fixture()
        let anchor = try StateDirectoryAnchor(storage: RuntimeStorage(root: fixture.root))
        #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try anchor.withFile(.writeJournal, protection: .verifyOnly) { _ in Issue.record("Opened writable state") }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appending(path: "journal.ndjson").path))
    }

    @Test func replacedFileIsRefusedByTheExistingPostReadChecks() throws {
        let fixture = try Fixture()
        try fixture.prepare()
        let storage = try #require(RuntimeStorage.existing(root: fixture.root))
        let anchor = try StateDirectoryAnchor(storage: storage)
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try anchor.withFile(.readSnapshot, protection: .verifyOnly) { fd in
                let bytes = try StateFileIO.readAll(fd, from: 0, name: .snapshot)
                try FileManager.default.moveItem(at: fixture.snapshot, to: fixture.state.appending(path: "retained"))
                try fixture.write(bytes)
                return bytes
            }
        }
        #expect(FileManager.default.fileExists(atPath: fixture.state.appending(path: "retained").path))
    }

    @Test(arguments: [StorageFailure.protectionDrift, .unsafeStructure, .inspectionFailed])
    func knownFactoryFailuresPreserveProtectionGuidance(failure: StorageFailure) {
        let reason: StateStoreError.ProtectionFailure = switch failure {
        case .protectionDrift: .permissions
        case .unsafeStructure: .changed
        default: .unreadable
        }
        #expect(throws: StateStoreError.insecureDirectory(reason: reason)) {
            try StateStore.inspectSnapshot(storage: { throw failure })
        }
    }

    @Test func arbitraryFactoryFailureUsesClosedErrorGuidance() {
        #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) {
            try StateStore.inspectSnapshot(storage: { throw NSError(domain: "private-fixture-marker", code: 1) })
        }
    }

    @Test(arguments: [false, true]) func inspectionBudgetIsBoundedAndPreservesOversizedState(oversized: Bool) throws {
        let fixture = try Fixture()
        let document = try JSONEncoder().encode(EnvironmentsSnapshot.empty)
        var bytes = Data(repeating: 0x20, count: StateStore.inspectionByteLimit + (oversized ? 1 : 0))
        bytes.replaceSubrange(0..<document.count, with: document)
        try fixture.prepare(bytes: bytes)
        let before = try fixture.version(fixture.snapshot)
        if oversized {
            #expect(throws: StateStoreError.fileUnreadable(name: .snapshot)) { try fixture.inspect() }
        } else { #expect(try fixture.inspect() == .empty) }
        #expect(try Data(contentsOf: fixture.snapshot) == bytes)
        #expect(try fixture.version(fixture.snapshot) == before)
    }

    private final class Fixture: Sendable {
        let base: URL
        var root: URL { base.appending(path: "Guesthouse") }
        var state: URL { root.appending(path: "state") }
        var snapshot: URL { state.appending(path: "environments.json") }
        init() throws {
            var template = Array("/private/tmp/guesthouse-state-inspection-XXXXXX".utf8CString)
            guard let path = mkdtemp(&template) else { throw StorageFailure.inspectionFailed }
            base = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) } // Only this mkdtemp-owned fixture.
        func inspect() throws -> EnvironmentsSnapshot {
            try StateStore.inspectSnapshot(storage: { try RuntimeStorage.existing(root: self.root) })
        }
        func prepare(bytes: Data? = nil) throws {
            _ = try RuntimeStorage(root: root)
            try write(bytes ?? JSONEncoder().encode(EnvironmentsSnapshot.empty))
        }
        func write(_ bytes: Data) throws {
            try bytes.write(to: snapshot)
            try #require(chmod(snapshot.path, 0o600) == 0)
        }
        func version(_ url: URL) throws -> StateFileVersion {
            var value = stat()
            try #require(lstat(url.path, &value) == 0)
            return StateFileVersion(value)
        }
    }
}
