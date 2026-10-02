import Darwin
import Dispatch
import Foundation
import GuesthouseCore

/// Single runtime owner of saved metadata (MVP §3, ADR 0004, #76).
/// Adapted from #217's snapshot store; the directory lock now spans the owner's lifetime,
/// replacing peer-observation state. No provider or guest-disk operation is performed here.
public actor StateStore {
    private var anchor: StateDirectoryAnchor?
    private let hooks: StateStoreHooks
    private let serviceEpoch = UUID()
    private var lumePublicationUncertain = false
    private var lumeOwnedChild: OwnedChild?
    private var selectingStorage = false
    private var canSave = false
    private var snapshotWasPresent = false
    private var journalWasPresent = false
    private var canAppend = false
    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private init(anchor: sending StateDirectoryAnchor, hooks: StateStoreHooks, queue: DispatchSerialQueue) {
        self.anchor = anchor
        self.hooks = hooks
        self.queue = queue
    }

    /// Reopen the runtime-selected, already prepared layout without creating or repairing it.
    /// Missing/insecure storage requires explicit setup/repair; opening establishes no readiness.
    public static func open() async throws(StateStoreError) -> StateStore {
        try await open(storage: { try RuntimeStorage(existingRoot: RuntimeStorage.defaultRoot()) })
    }

    static func open(storage: @escaping @Sendable () throws -> RuntimeStorage,
                     hooks: StateStoreHooks = StateStoreHooks()) async throws(StateStoreError) -> StateStore {
        try await make(anchor: { try StateDirectoryAnchor(storage: storage()) }, hooks: hooks)
    }

    /// Explicit first setup only, at the service-owned location. Success means both layout
    /// ownership and volume metadata are retained. Failure preserves partial state for inspection.
    public static func createFresh() async throws(StateStoreError) -> StateStore {
        try await createFresh(root: RuntimeStorage.defaultRoot)
    }

    static func createFresh(root: @escaping @Sendable () throws -> URL,
                            backup: @escaping RuntimeStorage.BackupWriter = RuntimeStorage.writeBackupExclusion,
                            hooks: StateStoreHooks = StateStoreHooks()) async throws(StateStoreError) -> StateStore {
        let store = try await make(anchor: {
            try RuntimeStorage.withFreshLayout(at: root(), backup: backup) { storage, descriptor in
                // dup retains the SAME flock ownership across handoff; no unlock/relock gap.
                try StateDirectoryAnchor(storage: storage, openDirectory: { _, _ in
                    fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                })
            }
        }, hooks: hooks)
        do {
            _ = try await store.selectStorageVolume()
            try await store.initializeFreshLumeOwnership()
            return store
        } catch {
            await store.close()
            throw error
        }
    }

    private static func make(anchor makeAnchor: @escaping @Sendable () throws -> StateDirectoryAnchor,
                             hooks: StateStoreHooks) async throws(StateStoreError) -> StateStore {
        // Keep blocking filesystem calls off the cooperative pool and the GUI's main actor.
        let queue = DispatchSerialQueue(label: "ai.picomlx.guesthouse.state-store", qos: .utility)
        let result: Result<StateStore, StateStoreError> = await withCheckedContinuation { continuation in
            queue.async {
                let result: Result<StateStore, StateStoreError>
                do {
                    let anchor = try makeAnchor()
                    try anchor.withDescriptor { descriptor in
                        guard StateFileIO.lock(descriptor, LOCK_EX | LOCK_NB) else {
                            throw StateStoreError.fileUnwritable(name: .stateDirectory)
                        }
                    }
                    try anchor.synchronizePreparation()
                    result = .success(StateStore(anchor: anchor, hooks: hooks, queue: queue))
                } catch let failure as StateStoreError { result = .failure(failure) }
                catch StorageFailure.protectionDrift { result = .failure(.insecureDirectory(reason: .permissions)) }
                catch StorageFailure.unsafeStructure { result = .failure(.insecureDirectory(reason: .changed)) }
                catch { result = .failure(.insecureDirectory(reason: .unreadable)) }
                continuation.resume(returning: result)
            }
        }
        return try result.get()
    }

    /// Releases ownership after earlier synchronous actor transactions complete. No disk is deleted.
    /// The runtime must quiesce its operations before closing. This store cannot be reopened in place.
    public func close() { canSave = false; canAppend = false; anchor = nil }

    /// Explicit optional setup, never ordinary reopening or launch. Reuses this owner's
    /// lifetime state lock and the shared physical-root lease instead of adding another writer.
    /// Runtime-only, fixed paths; no provider is executed and no VM mutation is authorized.
    func prepareLumeProbeConfiguration(
        coordinator: LumeRuntimeCoordinator = .shared
    ) async throws {
        guard let storage = try anchor?.verifiedProbeStorage() else {
            throw StateStoreError.fileUnreadable(name: .stateDirectory)
        }
        try await coordinator.withExclusiveAccess(for: storage) {
            try await self.prepareOwnedLumeProbeConfiguration()
        }
    }

    private func prepareOwnedLumeProbeConfiguration() throws {
        // close() may have run while waiting for the lease. Never mutate after losing ownership.
        guard let anchor else { throw StateStoreError.fileUnreadable(name: .stateDirectory) }
        _ = try requireLumeAvailability(anchor)
        try anchor.prepareLumeProbeConfiguration()
    }

    /// Internal fixed-command launch groundwork (MVP-PLAN.md §§3–4). Not wired to XPC,
    /// the GUI or production mutations. The historical pin still fails strict verification.
    /// Returning retains intent and actual authority; separate explicit inspection is required.
    func launchLumeProbe(command: LumeLaunchIntent.Command,
                         coordinator: LumeRuntimeCoordinator = .shared) async throws -> LumeProbeLaunch {
        guard let storage = try anchor?.verifiedProbeStorage() else {
            throw StateStoreError.fileUnreadable(name: .stateDirectory)
        }
        return try await coordinator.withExclusiveAccess(for: storage) {
            try await self.launchOwnedLumeProbe(command: command)
        }
    }

    private func launchOwnedLumeProbe(command: LumeLaunchIntent.Command) throws -> LumeProbeLaunch {
        // Recheck the current owner after queueing; never carry its old anchor across that wait.
        guard let anchor else { throw StateStoreError.fileUnreadable(name: .stateDirectory) }
        _ = try requireLumeAvailability(anchor)
        guard lumeOwnedChild == nil else { throw LumeLaunchOwnershipFailure.inspectionRequired }
        let storage = try anchor.verifiedProbeStorage()
        _ = try storage.environmentForLumeProbe()
        guard let bundle = try LumeBundle.locate(in: storage) else { throw LumeVerificationError.bundleMissing }
        let verified = try bundle.verify() // Precheck refusal creates no launch intent/effects.
        try Task.checkCancellation()
        let intent = try recordOwnedLumeLaunch(command: command)
        try Task.checkCancellation()
        // Publication may have taken time. Repeat the complete strict/coherence gate and
        // writable-path checks immediately before the same synchronous spawner, under lease.
        let current = try verified.reverified(in: storage)
        let invocation = try LumeProbeInvocation.make(executable: current.executable, command: command, storage: storage)
        let spawned = try ProcessRunner().spawn(invocation, runID: intent.attemptID)
        do { try attachOwnedLumeChild(spawned.run.ownedChild, to: intent) }
        catch {
            // Even unavailable birth/failed receipt publication retains the actual owner.
            // Requesting direct-child termination proves no cleanup or descendant outcome.
            if lumeOwnedChild == nil { lumeOwnedChild = spawned.run.ownedChild }
            let run = spawned.run
            Task { await run.terminate(gracePeriod: .seconds(1)) }
            throw error
        }
        return LumeProbeLaunch(intent: intent, run: spawned.run)
    }

    /// Admission seam for the future fixed-command probe. The physical-root lease spans
    /// publication and the caller; the durable intent continues blocking admission afterward.
    /// All other provider mutations/replacement remain disabled until wired to this authority
    /// and an actual whole-owned-set inspector. This is not a generic process/XPC API.
    func withLumeLaunchIntent<T: Sendable>(
        command: LumeLaunchIntent.Command, coordinator: LumeRuntimeCoordinator = .shared,
        operation: @Sendable (LumeLaunchIntent) async throws -> T
    ) async throws -> T {
        guard let storage = try anchor?.verifiedProbeStorage() else {
            throw StateStoreError.fileUnreadable(name: .stateDirectory)
        }
        return try await coordinator.withExclusiveAccess(for: storage) {
            try Task.checkCancellation()
            let intent = try await self.recordOwnedLumeLaunch(command: command)
            try Task.checkCancellation()
            return try await operation(intent)
        }
    }

    private func initializeFreshLumeOwnership() throws(StateStoreError) {
        guard let anchor else { throw StateStoreError.fileUnreadable(name: .stateDirectory) }
        // Called solely from createFresh after exclusive root creation, never from open/repair.
        guard try anchor.withFile(.inspectRuntimeOwnership, body: { _ in true }) == nil else {
            throw .setupRequiresInspection
        }
        let root: StateFileIdentity
        do { root = try anchor.verifiedProbeStorage().coordinationIdentity() }
        catch let error as StateStoreError { throw error }
        catch { throw .insecureDirectory(reason: .changed) }
        try publishLumeOwnership(LumeRuntimeOwnership(root: root), anchor: anchor)
    }

    private func recordOwnedLumeLaunch(command: LumeLaunchIntent.Command) throws -> LumeLaunchIntent {
        // close() may run while queued. Never retain the old anchor/lock across that wait.
        guard let anchor else { throw StateStoreError.fileUnreadable(name: .stateDirectory) }
        let saved = try requireLumeAvailability(anchor)
        let intent = LumeLaunchIntent(operationID: UUID(), serviceEpoch: serviceEpoch,
                                      attemptID: UUID(), command: command)
        try publishLumeOwnership(LumeRuntimeOwnership(root: saved.root, intent: intent), anchor: anchor)
        return intent
    }

    private func requireLumeAvailability(_ anchor: StateDirectoryAnchor) throws -> LumeRuntimeOwnership {
        let saved = try readLumeOwnership(anchor)
        guard saved.intent == nil else { throw LumeLaunchOwnershipFailure.inspectionRequired }
        return saved
    }

    /// Attach only a child constructed by the existing spawner to this owner's exact attempt.
    /// Do this even after cancellation: effects already happened. Neither attachment, caller
    /// return nor direct-child reaping settles the durable intent or proves descendants quiet.
    func attachOwnedLumeChild(_ child: OwnedChild, to intent: LumeLaunchIntent) throws {
        guard let anchor else { throw StateStoreError.fileUnreadable(name: .stateDirectory) }
        let saved = try readLumeOwnership(anchor)
        guard saved.intent == intent, intent.serviceEpoch == serviceEpoch,
              saved.child == nil, lumeOwnedChild == nil,
              child.runID == intent.attemptID, let identity = child.launchIdentity,
              identity.isConsistent else { throw LumeLaunchOwnershipFailure.inspectionRequired }
        // Keep actual authority even if the attachment's publication fails. The previous
        // intent already blocks restart; failure never grants permission to replace/retry.
        lumeOwnedChild = child
        try publishLumeOwnership(LumeRuntimeOwnership(root: saved.root, intent: intent, child: identity), anchor: anchor)
    }

    /// Explicit same-service inspection of the retained actual child (MVP-PLAN.md §§3–4).
    /// Kernel launch history must prove that this owned set contained no descendants and
    /// its exclusive reaper completed. Forked launches, lost authority and restart stay blocked.
    /// This neither repairs provider inventory nor grants VM/restart/signal authority.
    func settleInspectedLumeLaunch(
        _ intent: LumeLaunchIntent, coordinator: LumeRuntimeCoordinator = .shared
    ) async throws {
        guard let storage = try anchor?.verifiedProbeStorage() else {
            throw StateStoreError.fileUnreadable(name: .stateDirectory)
        }
        try await coordinator.withExclusiveAccess(for: storage) {
            try await self.settleOwnedLumeLaunch(intent)
        }
    }

    private func settleOwnedLumeLaunch(_ intent: LumeLaunchIntent) throws {
        // Never retain an anchor/lease as authority after close() or a queued root change.
        guard let anchor else { throw StateStoreError.fileUnreadable(name: .stateDirectory) }
        let saved = try readLumeOwnership(anchor)
        guard saved.intent == intent, intent.serviceEpoch == serviceEpoch,
              let child = lumeOwnedChild, let identity = child.launchIdentity,
              identity.runID == intent.attemptID, saved.child == identity,
              child.forkObservation == .exitedWithoutFork else {
            throw LumeLaunchOwnershipFailure.inspectionRequired
        }
        try Task.checkCancellation()
        // Keep actual authority on every publication failure, including post-rename failure.
        // The existing uncertainty fence then refuses both settlement retry and new launches.
        try publishLumeOwnership(LumeRuntimeOwnership(root: saved.root), anchor: anchor)
        lumeOwnedChild = nil
    }

    private func readLumeOwnership(_ anchor: StateDirectoryAnchor) throws -> LumeRuntimeOwnership {
        guard !lumePublicationUncertain else { throw LumeLaunchOwnershipFailure.inspectionRequired }
        let raw = try anchor.withFile(.inspectRuntimeOwnership) {
            try StateFileIO.readAll($0, from: 0, name: .runtimeOwnership)
        }
        guard let raw else { throw LumeLaunchOwnershipFailure.inspectionRequired }
        let saved: LumeRuntimeOwnership
        do { saved = try JSONDecoder().decode(LumeRuntimeOwnership.self, from: raw) }
        catch let error as LumeLaunchOwnershipFailure { throw error }
        catch { throw LumeLaunchOwnershipFailure.corruptRecord }
        let root = try anchor.verifiedProbeStorage().coordinationIdentity()
        guard saved.root == root else { throw LumeLaunchOwnershipFailure.changedRoot }
        return saved
    }

    private func publishLumeOwnership(_ value: LumeRuntimeOwnership, anchor: StateDirectoryAnchor) throws(StateStoreError) {
        let data: Data
        do { data = try JSONEncoder().encode(value) }
        catch { throw .unencodable(name: .runtimeOwnership) }
        guard data.count <= StateFileIO.maximumRuntimeOwnershipBytes else {
            throw StateStoreError.unencodable(name: .runtimeOwnership)
        }
        lumePublicationUncertain = true
        try anchor.replace(data, at: .inspectRuntimeOwnership, hooks: hooks, write: hooks.ownershipWrite)
        lumePublicationUncertain = false
    }

    /// Missing metadata is an empty inventory, never authority to recreate a VM.
    /// Verification never repairs file permissions. Drift requires explicit repair.
    /// A successful read permits metadata saving, not host/guest mutations or job replay.
    public func loadSnapshot() throws(StateStoreError) -> EnvironmentsSnapshot {
        canSave = false
        guard let anchor else { throw .fileUnreadable(name: .stateDirectory) }
        let value = try readSnapshot(anchor)
        canSave = true
        return value
    }

    /// Requires this owner to load first. A failed publication blocks subsequent saves until
    /// explicitly reloaded; even an error after rename may have made the new snapshot visible.
    public func saveSnapshot(_ snapshot: EnvironmentsSnapshot) throws(StateStoreError) {
        guard let anchor, canSave else { throw .fileUnwritable(name: .snapshot) }
        canSave = false
        try snapshot.validate()
        let data: Data
        do { data = try JSONEncoder().encode(snapshot) }
        catch { throw .unencodable(name: .snapshot) }
        guard data.count <= StateFileIO.maximumSnapshotBytes else { throw .unencodable(name: .snapshot) }
        // Preserve unsupported/corrupt on-disk records even if the proposed value is valid.
        let existing = try readSnapshot(anchor)
        guard existing.storageSelection == snapshot.storageSelection || selectingStorage else {
            throw StateStoreError.storageSelectionChanged
        }
        // An ordinary save must not make unknown prior placement look like fresh setup.
        // Removing this last evidence requires explicit inspected recovery/discard, not
        // an empty intermediate snapshot followed by selecting the current volume.
        guard existing.storageSelection != nil || existing.environments.isEmpty || !snapshot.environments.isEmpty else {
            throw StateStoreError.storageSelectionChanged
        }
        // Preserve the observed-file guard even if a post-rename directory barrier fails.
        try anchor.replace(data, at: .inspectSnapshot, hooks: hooks, write: hooks.write,
                           didPublish: { self.snapshotWasPresent = true })
        canSave = true
    }

    func storageDestination() throws(StateStoreError) -> URL {
        guard let anchor else { throw .fileUnreadable(name: .stateDirectory) }
        do { return try anchor.storageDestination() }
        catch { throw .insecureDirectory(reason: .unreadable) }
    }

    /// Explicit setup only. Unknown identity may be selected only for an empty inventory,
    /// empty journal and empty VM directory. Ordinary saves can neither select nor replace it.
    /// No GUI path or UUID is accepted; the existing runtime-chosen destination supplies both.
    func selectStorageVolume() throws(StateStoreError) -> EnvironmentsSnapshot {
        guard let anchor else { throw .fileUnreadable(name: .stateDirectory) }
        var snapshot = try loadSnapshot()
        guard snapshot.storageSelection == nil else { return snapshot }
        let journal = try replay()
        guard snapshot.environments.isEmpty, journal.records.isEmpty, !journal.truncatedTail else {
            throw .storageSelectionChanged
        }
        let selection: HostStorageSelection
        do {
            let destination = try anchor.storageDestination()
            guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
                  let value = HostStorageSelection(volumeID: try SystemStorageProbe.identifyVolume(atExistingDirectory: destination)) else {
                throw StateStoreError.storageSelectionChanged
            }
            selection = value
        } catch { throw .storageSelectionChanged }
        snapshot.storageSelection = selection
        selectingStorage = true
        defer { selectingStorage = false }
        try saveSnapshot(snapshot)
        return snapshot
    }

    /// Inspect saved operation history before admitting any new record. Replay never starts
    /// an operation or removes bytes. An incomplete tail requires explicit repair (ADR 0004).
    public func replay() throws(StateStoreError) -> JournalReplay {
        canAppend = false
        guard let anchor else { throw .fileUnreadable(name: .journal) }
        let chunk = try anchor.withFile(.inspectJournal, didOpen: { self.journalWasPresent = true }) { descriptor in
            let chunk = try JournalReplayChunk(StateFileIO.readAll(descriptor, from: 0, name: .journal))
            // A previous failed append may have left complete but unflushed bytes visible.
            try hooks.synchronize(descriptor, .journal)
            return chunk
        }
        guard chunk != nil || !journalWasPresent else { throw .fileUnreadable(name: .journal) }
        try anchor.withDescriptor { try hooks.synchronize($0, .stateDirectory) }
        let value: JournalReplayChunk
        if let chunk { value = chunk } else { value = try JournalReplayChunk(Data()) }
        canAppend = !value.truncatedTail
        return JournalReplay(records: value.history.records, inFlight: value.history.inFlight,
                             truncatedTail: value.truncatedTail)
    }

    /// Return an operation identity only after its start record has been saved. If this throws,
    /// inspect the journal and actual state before retrying any associated host/guest mutation.
    public func begin(_ operation: JournalOperation, for environmentID: EnvironmentID,
                      at timestamp: Date = Date()) throws(StateStoreError) -> OperationID {
        let id = OperationID()
        try append(JournalRecord(id: id, environmentID: environmentID, operation: operation,
                                 timestamp: timestamp, outcome: .started))
        return id
    }

    /// Reuses the pure history/framing rules from #197/#199 and the in-scope append transaction
    /// from #214. The lifetime directory lock has one owner; no peer cache/observation registry.
    /// Whole-file replay is bounded to 16 MiB. Full history is preserved when that budget is met.
    public func append(_ record: JournalRecord) throws(StateStoreError) {
        guard let anchor, canAppend else { throw .fileUnwritable(name: .journal) }
        canAppend = false
        let encoded: Data
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do { encoded = try encoder.encode(record) }
        catch { throw .unencodable(name: .journal) }
        var attemptedWrite = false
        do {
            _ = try anchor.withFile(.writeJournal, requireExisting: journalWasPresent,
                                    didOpen: { self.journalWasPresent = true }) { descriptor in
                let bytes = try StateFileIO.readAll(descriptor, from: 0, name: .journal)
                let chunk = try JournalReplayChunk(bytes)
                guard !chunk.truncatedTail else {
                    throw StateStoreError.corruptJournal(line: chunk.history.records.count + 1)
                }
                try chunk.history.validateAppend(record)
                var addition = chunk.unterminatedRecord ? Data([0x0A]) : Data()
                addition.append(encoded)
                addition.append(0x0A)
                guard addition.count <= StateFileIO.maximumJournalBytes - bytes.count else {
                    throw StateStoreError.fileUnwritable(name: .journal)
                }
                // readAll left this private descriptor at EOF. No truncation or repair occurs.
                attemptedWrite = true
                try hooks.journalWrite(descriptor, addition)
                try hooks.synchronize(descriptor, .journal)
            }
            try anchor.withDescriptor { try hooks.synchronize($0, .stateDirectory) }
        } catch {
            if attemptedWrite { throw .journalWriteUncertain(cause: error) }
            throw error
        }
        canAppend = true
    }

    private func readSnapshot(_ anchor: StateDirectoryAnchor) throws(StateStoreError) -> EnvironmentsSnapshot {
        let value = try anchor.withFile(.inspectSnapshot, body: { descriptor in
            let raw = try StateFileIO.readAll(descriptor, from: 0, name: .snapshot)
            let migrated = try SnapshotMigrator.standard.migrate(raw)
            do { return try JSONDecoder().decode(EnvironmentsSnapshot.self, from: migrated.data) }
            catch let failure as StateStoreError { throw failure }
            catch { throw StateStoreError.corruptSnapshot }
        })
        guard value != nil || !snapshotWasPresent else { throw .fileUnreadable(name: .snapshot) }
        snapshotWasPresent = value != nil
        return value ?? .empty
    }
}

/// Internal synchronous fault seams. Borrowed descriptors never escape or cross a suspension.
struct StateStoreHooks: Sendable {
    var journalWrite: @Sendable (Int32, Data) throws -> Void = { try StateFileIO.writeAll($0, $1, name: .journal) }
    var write: @Sendable (Int32, Data) throws -> Void = { try StateFileIO.writeAll($0, $1, name: .snapshot) }
    var ownershipWrite: @Sendable (Int32, Data) throws -> Void = { try StateFileIO.writeAll($0, $1, name: .runtimeOwnership) }
    var synchronize: @Sendable (Int32, StateStoreError.File) throws -> Void = {
        try StateFileIO.fullySynchronize($0, name: $1)
    }
}
