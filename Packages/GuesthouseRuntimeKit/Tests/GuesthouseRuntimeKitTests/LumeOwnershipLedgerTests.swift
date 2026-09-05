import Darwin
import Foundation
import Testing
@testable import GuesthouseRuntimeKit

// Real durability barriers share host storage. Bound their I/O pressure while unrelated
// process suites exercise wall-clock deadlines; cases still use independent fixture roots.
@Suite(.serialized) struct LumeOwnershipLedgerTests {
    private struct Fixture {
        let storage: RuntimeStorage
        let marker: URL
        let ledger: URL
        let owner: LumeOwnershipIdentity
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "LumeLedger-\(UUID())")
        let storage = try RuntimeStorage(root: root)
        let identity = try storage.coordinationIdentity()
        let enrollment = LumeOwnershipEnrollment(format: 1, id: UUID(), rootDevice: Int64(identity.device),
                                                 rootInode: UInt64(identity.inode))
        let marker = root.appending(path: LumeOwnershipGuard.fileName)
        // Synthetic test-only enrollment. No production bootstrap authority exists.
        try write(JSONEncoder().encode(enrollment), to: marker)
        let guardIdentity = try #require(RuntimeStorage.fileIdentity(of: marker))
        let ledger = root.appending(path: LumeOwnershipLedger.fileName)
        let genesis = LumeOwnershipLedgerEnvelope(format: 1, enrollment: enrollment,
            guardDevice: Int64(guardIdentity.device), guardInode: UInt64(guardIdentity.inode), value: .genesis)
        try write(JSONEncoder().encode(genesis), to: ledger)
        return Fixture(storage: storage, marker: marker, ledger: ledger,
            owner: .init(rootDevice: enrollment.rootDevice, rootInode: enrollment.rootInode,
                         operationID: UUID(), serviceEpoch: UUID(), generation: UUID()))
    }

    private func owned(_ snapshot: LumeOwnershipLedgerSnapshot) throws -> LumeOwnershipRecord {
        guard case .owned(let record) = snapshot.value else { throw LumeOwnershipFailure.invalidRecord }
        return record
    }

    @Test(arguments: LumeCleanupObservation.allCases)
    func everyLegacyOutcomeRemainsQuarantinedAcrossReopening(observation: LumeCleanupObservation) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        let store = try LumeOwnershipLedger(storage: f.storage)
        let reserved = try store.apply(.reserve(f.owner), expected: store.read())
        let running = try store.apply(.registerLaunch(UUID(), owner: f.owner), expected: reserved)
        let blocked = try store.apply(.observe(observation, owner: f.owner), expected: running)
        #expect(try owned(blocked).phase == .quarantined(observation.reason))
        let reopened = try LumeOwnershipLedger(storage: f.storage)
        let recovered = try reopened.read()
        #expect(try owned(recovered).phase == .quarantined(.restarted))
        #expect(try owned(recovered).attemptIDs == owned(running).attemptIDs)
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try reopened.apply(.reserve(f.owner), expected: recovered) }
    }

    @Test func reopeningEvenANoSpawnReservationCannotInheritFinishAuthority() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        let store = try LumeOwnershipLedger(storage: f.storage)
        _ = try store.apply(.reserve(f.owner), expected: store.read())
        let reopened = try LumeOwnershipLedger(storage: f.storage)
        #expect(throws: LumeOwnershipFailure.invalidTransition) {
            try reopened.apply(.finish(owner: f.owner), expected: reopened.read())
        }
    }

    @Test func syntheticCompleteInspectionSettlesButNeverResumesAnInterruptedOperation() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        let store = try LumeOwnershipLedger(storage: f.storage)
        let reserved = try store.apply(.reserve(f.owner), expected: store.read())
        let running = try store.apply(.registerLaunch(UUID(), owner: f.owner), expected: reserved)
        let blocked = try store.apply(.observe(.terminationRefused, owner: f.owner), expected: running)
        let record = try owned(blocked)
        let synthetic = LumeOwnedSetInspection(identity: f.owner, revision: record.revision,
            attemptIDs: record.attemptIDs, conclusion: .entireOwnedSetQuiescent)
        let settled = try store.apply(.inspect(synthetic), expected: blocked)
        #expect(try owned(settled).phase == .settled)
        let reopened = try LumeOwnershipLedger(storage: f.storage)
        #expect(try reopened.read().value == settled.value)
    }

    @Test func staleConcurrentReservationPoisonsTheLosingStore() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        let first = try LumeOwnershipLedger(storage: f.storage)
        let second = try LumeOwnershipLedger(storage: f.storage)
        let stale = try second.read()
        _ = try first.apply(.reserve(f.owner), expected: first.read())
        #expect(throws: LumeOwnershipStorageFailure.staleRecord) { try second.apply(.reserve(f.owner), expected: stale) }
        #expect(throws: LumeOwnershipStorageFailure.poisoned) { try second.read() }
    }

    @Test(arguments: ["both", "guard", "ledger"])
    func missingEnrollmentFilesNeverRecreateIdleState(missing: String) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        for (name, file) in [("guard", f.marker), ("ledger", f.ledger)] where missing == "both" || missing == name {
            try FileManager.default.moveItem(at: file, to: f.storage.root.appending(path: "preserved-\(name)"))
        }
        #expect(throws: LumeOwnershipStorageFailure.notEnrolled) { try LumeOwnershipLedger(storage: f.storage) }
        if missing != "guard" { #expect(!FileManager.default.fileExists(atPath: f.ledger.path)) }
        if missing != "ledger" { #expect(!FileManager.default.fileExists(atPath: f.marker.path)) }
    }

    @Test(arguments: ["future", "enrollment", "guard-inode", "foreign-owner", "malformed", "oversized", "mode", "link"])
    func invalidLedgerCannotAuthorizeMutation(kind: String) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        let original = try JSONDecoder().decode(LumeOwnershipLedgerEnvelope.self, from: Data(contentsOf: f.ledger))
        var value = original.value
        if kind == "foreign-owner" {
            value = .owned(.init(reserving: .init(rootDevice: f.owner.rootDevice, rootInode: f.owner.rootInode + 1,
                operationID: UUID(), serviceEpoch: UUID(), generation: UUID())))
        }
        let enrollment = original.enrollment
        let invalid = LumeOwnershipLedgerEnvelope(format: kind == "future" ? 2 : 1,
            enrollment: .init(format: 1, id: kind == "enrollment" ? UUID() : enrollment.id,
                              rootDevice: enrollment.rootDevice, rootInode: enrollment.rootInode),
            guardDevice: original.guardDevice, guardInode: original.guardInode + (kind == "guard-inode" ? 1 : 0), value: value)
        try write(JSONEncoder().encode(invalid), to: f.ledger)
        if kind == "malformed" { try write(Data("{}".utf8), to: f.ledger) }
        if kind == "oversized" { try write(Data(repeating: 32, count: 32_769), to: f.ledger) }
        if kind == "mode" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.ledger.path) }
        if kind == "link" {
            let preserved = f.storage.root.appending(path: "preserved")
            try FileManager.default.moveItem(at: f.ledger, to: preserved)
            try FileManager.default.createSymbolicLink(at: f.ledger, withDestinationURL: preserved)
        }
        #expect(throws: LumeOwnershipStorageFailure.self) { try LumeOwnershipLedger(storage: f.storage) }
    }

    @Test func copyingTheMarkerCannotTransferItsLedgerAuthority() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        let bytes = try Data(contentsOf: f.marker)
        try FileManager.default.moveItem(at: f.marker, to: f.storage.root.appending(path: "preserved"))
        try write(bytes, to: f.marker)
        #expect(throws: LumeOwnershipStorageFailure.invalidLedger) { try LumeOwnershipLedger(storage: f.storage) }
    }

    @Test(arguments: ["temporary-file", "publication-directory", "post-barrier-replacement", "temporary-drift"])
    func uncertainPublicationNeverReleasesOrRetriesOwnership(fault: String) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        var enabled = false
        var files = 0
        var directories = 0
        let store = try LumeOwnershipLedger(storage: f.storage) { fd in
            try LumeOwnershipIO.synchronize(fd)
            guard enabled else { return }
            let info = try LumeOwnershipIO.info(fd)
            if info.st_mode & S_IFMT == S_IFREG { files += 1 }
            if info.st_mode & S_IFMT == S_IFDIR { directories += 1 }
            if fault == "temporary-file", files == 2 { throw LumeOwnershipStorageFailure.ioFailure }
            if fault == "temporary-drift", info.st_mode & S_IFMT == S_IFDIR, directories == 2 {
                let names = try FileManager.default.contentsOfDirectory(atPath: f.storage.root.path)
                let temporary = try #require(names.first { $0.hasPrefix(".lume-ownership.tmp-") })
                try FileManager.default.setAttributes([.posixPermissions: 0o644],
                    ofItemAtPath: f.storage.root.appending(path: temporary).path)
            }
            if info.st_mode & S_IFMT == S_IFDIR, directories == 3 {
                if fault == "publication-directory" { throw LumeOwnershipStorageFailure.ioFailure }
                if fault == "post-barrier-replacement" {
                    let bytes = try Data(contentsOf: f.ledger)
                    try FileManager.default.moveItem(at: f.ledger, to: f.storage.root.appending(path: "preserved-ledger"))
                    try write(bytes, to: f.ledger)
                }
            }
        }
        let reserved = try store.apply(.reserve(f.owner), expected: store.read())
        enabled = true
        #expect(throws: LumeOwnershipStorageFailure.writeUncertain) {
            try store.apply(.registerLaunch(UUID(), owner: f.owner), expected: reserved)
        }
        #expect(throws: LumeOwnershipStorageFailure.poisoned) { try store.read() }
        enabled = false
        let reopened = try LumeOwnershipLedger(storage: f.storage)
        let current = try reopened.read()
        #expect(try owned(current).phase == .quarantined(.restarted))
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try reopened.apply(.reserve(f.owner), expected: current) }
    }

    @Test func everyPublicationIncludesANewDirectoryBarrier() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        var enabled = false
        var directories = 0
        let store = try LumeOwnershipLedger(storage: f.storage) { fd in
            try LumeOwnershipIO.synchronize(fd)
            if enabled, try LumeOwnershipIO.info(fd).st_mode & S_IFMT == S_IFDIR { directories += 1 }
        }
        let genesis = try store.read()
        enabled = true
        let reserved = try store.apply(.reserve(f.owner), expected: genesis)
        #expect(directories == 3, "initial reread, pre-rename reread, and publication each synchronize")
        directories = 0
        let settled = try store.apply(.finish(owner: f.owner), expected: reserved)
        #expect(directories == 3)
        #expect(try owned(settled).phase == .settled)
    }

    @Test(arguments: [false, true])
    func laterReservationsRequireFreshOperationAndGeneration(reuseGeneration: Bool) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.storage.root) }
        let store = try LumeOwnershipLedger(storage: f.storage)
        let reserved = try store.apply(.reserve(f.owner), expected: store.read())
        let settled = try store.apply(.finish(owner: f.owner), expected: reserved)
        let reused = LumeOwnershipIdentity(rootDevice: f.owner.rootDevice, rootInode: f.owner.rootInode,
            operationID: reuseGeneration ? UUID() : f.owner.operationID, serviceEpoch: f.owner.serviceEpoch,
            generation: reuseGeneration ? f.owner.generation : UUID())
        #expect(throws: LumeOwnershipFailure.invalidTransition) { try store.apply(.reserve(reused), expected: settled) }
        let reopened = try LumeOwnershipLedger(storage: f.storage)
        let fresh = LumeOwnershipIdentity(rootDevice: f.owner.rootDevice, rootInode: f.owner.rootInode,
            operationID: UUID(), serviceEpoch: f.owner.serviceEpoch, generation: UUID())
        #expect(try owned(reopened.apply(.reserve(fresh), expected: reopened.read())).identity == fresh)
    }
}
