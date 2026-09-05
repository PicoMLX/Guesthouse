import Darwin
import Foundation

/// Explicit genesis is distinct from an absent, malformed or lost ownership ledger.
struct LumeOwnershipLedgerEnvelope: Codable, Equatable {
    enum Value: Codable, Equatable { case genesis, owned(LumeOwnershipRecord) }
    let format: Int
    let enrollment: LumeOwnershipEnrollment
    let guardDevice: Int64
    let guardInode: UInt64
    let value: Value

    func validate(enrollment: LumeOwnershipEnrollment, guardIdentity: RuntimeStorage.CoordinationIdentity) throws {
        guard format == 1, self.enrollment == enrollment,
              guardDevice == Int64(guardIdentity.device), guardInode == UInt64(guardIdentity.inode) else {
            throw LumeOwnershipStorageFailure.invalidLedger
        }
        if case .owned(let record) = value {
            guard record.identity.rootDevice == enrollment.rootDevice,
                  record.identity.rootInode == enrollment.rootInode else { throw LumeOwnershipStorageFailure.invalidLedger }
        }
    }
}

enum LumeOwnershipLedgerAction {
    case reserve(LumeOwnershipIdentity)
    case registerLaunch(UUID, owner: LumeOwnershipIdentity)
    case observe(LumeCleanupObservation, owner: LumeOwnershipIdentity)
    case finish(owner: LumeOwnershipIdentity)
    case inspect(LumeOwnedSetInspection)
    case restart

    func applying(to value: LumeOwnershipLedgerEnvelope.Value) throws -> LumeOwnershipRecord {
        if case .reserve(let identity) = self {
            if case .owned(let existing) = value {
                guard existing.phase == .settled, identity.generation != existing.identity.generation,
                      identity.operationID != existing.identity.operationID else {
                    throw LumeOwnershipFailure.invalidTransition
                }
            }
            return LumeOwnershipRecord(reserving: identity)
        }
        guard case .owned(let record) = value else { throw LumeOwnershipFailure.invalidTransition }
        switch self {
        case .reserve: throw LumeOwnershipFailure.invalidTransition
        case .registerLaunch(let id, let owner): return try record.registeringLaunch(id, owner: owner)
        case .observe(let observation, let owner): return try record.recording(observation, owner: owner)
        case .finish(let owner): return try record.finishing(owner: owner)
        case .inspect(let evidence): return try record.accepting(evidence)
        case .restart: return try record.recoveringAfterRestart()
        }
    }
}

struct LumeOwnershipLedgerSnapshot: Equatable {
    let value: LumeOwnershipLedgerEnvelope.Value
    fileprivate let envelope: LumeOwnershipLedgerEnvelope
    fileprivate let version: LumeOwnershipFileVersion
}

/// Inactive, synchronous, actor-confined persistence. No admission, enrollment or inspection
/// authority is supplied. The caller inherits the guard's stable root/ancestry lifetime contract.
/// Every update rereads under the permanent guard; no cached idle state can admit an operation.
final class LumeOwnershipLedger {
    static let fileName = ".lume-ownership.json"
    static let maximumBytes = 32_768
    private let guardFile: LumeOwnershipGuard
    private let barrier: (Int32) throws -> Void
    private var poisoned = false

    init(storage: RuntimeStorage, barrier: @escaping (Int32) throws -> Void = LumeOwnershipIO.synchronize) throws {
        guardFile = try LumeOwnershipGuard(storage: storage, barrier: barrier)
        self.barrier = barrier
        let current = try read()
        // A newly opened store cannot inherit a previous handle's operation authority, even
        // when no attempted launch was recorded. Conservatively orphan every unfinished owner.
        if case .owned(let record) = current.value, record.phase != .settled {
            _ = try apply(.restart, expected: current)
        }
    }

    func read() throws -> LumeOwnershipLedgerSnapshot {
        guard !poisoned else { throw LumeOwnershipStorageFailure.poisoned }
        do { return try guardFile.withLock { directory, _ in try readLocked(directory) } }
        catch { poisoned = true; throw error }
    }

    /// Exact-record compare-and-swap, including physical file version. The returned reservation
    /// or attempted-run intent MUST be durable before its associated effect is allowed to start.
    func apply(_ action: LumeOwnershipLedgerAction, expected: LumeOwnershipLedgerSnapshot) throws -> LumeOwnershipLedgerSnapshot {
        guard !poisoned else { throw LumeOwnershipStorageFailure.poisoned }
        var attemptedWrite = false
        do {
            return try guardFile.withLock { directory, _ in
                let current = try readLocked(directory)
                guard current == expected else { throw LumeOwnershipStorageFailure.staleRecord }
                let envelope = LumeOwnershipLedgerEnvelope(format: 1, enrollment: current.envelope.enrollment,
                    guardDevice: current.envelope.guardDevice, guardInode: current.envelope.guardInode,
                    value: .owned(try action.applying(to: current.value)))
                try envelope.validate(enrollment: guardFile.enrollment, guardIdentity: guardFile.identity)
                let bytes = try JSONEncoder().encode(envelope)
                guard bytes.count <= Self.maximumBytes else { throw LumeOwnershipStorageFailure.invalidLedger }
                let name = ".lume-ownership.tmp-\(UUID())"
                attemptedWrite = true
                let descriptor = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw LumeOwnershipStorageFailure.ioFailure }
                defer { close(descriptor) }
                // Failed temporaries are preserved as evidence, never used to reconstruct a
                // missing canonical ledger or automatically cleaned up as apparent orphans.
                try LumeOwnershipIO.requirePrivateFile(descriptor)
                try Self.write(bytes, to: descriptor)
                let writtenVersion = try LumeOwnershipIO.version(descriptor)
                try barrier(descriptor)
                guard try LumeOwnershipIO.version(descriptor) == writtenVersion else {
                    throw LumeOwnershipStorageFailure.guardChanged
                }
                try LumeOwnershipIO.requireEntry(descriptor, named: name, in: directory)
                guard try readLocked(directory) == current else { throw LumeOwnershipStorageFailure.staleRecord }
                try LumeOwnershipIO.requirePrivateFile(descriptor)
                try LumeOwnershipIO.requireEntry(descriptor, named: name, in: directory)
                guard try LumeOwnershipIO.version(descriptor) == writtenVersion else {
                    throw LumeOwnershipStorageFailure.guardChanged
                }
                guard renameat(directory, name, directory, Self.fileName) == 0 else {
                    throw LumeOwnershipStorageFailure.ioFailure
                }
                let publishedVersion = try LumeOwnershipIO.version(descriptor)
                let directoryVersion = try LumeOwnershipIO.version(directory)
                try barrier(directory) // Every publication, never a cached entry-durability bit.
                try guardFile.validate()
                try LumeOwnershipIO.requirePrivateFile(descriptor)
                try LumeOwnershipIO.requireEntry(descriptor, named: Self.fileName, in: directory)
                guard try LumeOwnershipIO.version(descriptor) == publishedVersion,
                      try LumeOwnershipIO.version(directory) == directoryVersion else {
                    throw LumeOwnershipStorageFailure.guardChanged
                }
                return .init(value: envelope.value, envelope: envelope, version: publishedVersion)
            }
        } catch {
            poisoned = true
            if attemptedWrite { throw LumeOwnershipStorageFailure.writeUncertain }
            throw error
        }
    }

    private func readLocked(_ directory: Int32) throws -> LumeOwnershipLedgerSnapshot {
        let descriptor = try LumeOwnershipIO.openExisting(Self.fileName, in: directory)
        defer { close(descriptor) }
        let version = try LumeOwnershipIO.version(descriptor)
        try LumeOwnershipIO.requirePrivateFile(descriptor)
        let bytes = try LumeOwnershipIO.readBounded(descriptor, limit: Self.maximumBytes)
        guard let envelope = try? JSONDecoder().decode(LumeOwnershipLedgerEnvelope.self, from: bytes) else {
            throw LumeOwnershipStorageFailure.invalidLedger
        }
        try envelope.validate(enrollment: guardFile.enrollment, guardIdentity: guardFile.identity)
        try barrier(descriptor)
        let directoryVersion = try LumeOwnershipIO.version(directory)
        try barrier(directory)
        try guardFile.validate()
        try LumeOwnershipIO.requirePrivateFile(descriptor)
        try LumeOwnershipIO.requireEntry(descriptor, named: Self.fileName, in: directory)
        guard try LumeOwnershipIO.version(descriptor) == version,
              try LumeOwnershipIO.version(directory) == directoryVersion else {
            throw LumeOwnershipStorageFailure.guardChanged
        }
        return .init(value: envelope.value, envelope: envelope, version: version)
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, data.count - offset) }
            if written > 0 { offset += written }
            else if written < 0, errno == EINTR { continue }
            else { throw LumeOwnershipStorageFailure.ioFailure }
        }
    }
}
