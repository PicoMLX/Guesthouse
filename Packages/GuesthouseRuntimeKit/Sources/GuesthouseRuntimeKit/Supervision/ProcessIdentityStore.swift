import Foundation
import GuesthouseCore

/// Persists the identities of processes the service launched, so a relaunched service can
/// recognize a survivor or refuse to guess (MVP-PLAN.md §4). Written atomically before the
/// process is reported as started; one file under the runtime's `state/` directory.
public actor ProcessIdentityStore {
    public static let fileName = "processes.json"

    public nonisolated let url: URL
    private var identities: [EnvironmentID: ProcessIdentity]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Dates are stored as `Date`'s own value (seconds since the reference date, full double
    /// precision), so a start time reads back bit-for-bit: the reconciler compares it for
    /// equality with the kernel's value. Converting to another epoch would round.
    public init(directory: URL) throws {
        url = directory.appending(path: Self.fileName)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .deferredToDate
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard FileManager.default.fileExists(atPath: url.path) else {
            identities = [:]
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProcessIdentityStoreError.unreadable(path: url.path, reason: SanitizedText(error.localizedDescription, limit: 120).value)
        }
        do {
            identities = try decoder.decode([EnvironmentID: ProcessIdentity].self, from: data)
        } catch {
            throw ProcessIdentityStoreError.unreadable(path: url.path, reason: "the file is not a valid process record")
        }
    }

    public var all: [EnvironmentID: ProcessIdentity] { identities }

    public func identity(for environment: EnvironmentID) -> ProcessIdentity? { identities[environment] }

    /// Records the identity durably. Returns only after the file is on disk; memory changes
    /// only then, so a failed write never leaves the actor describing state the disk lacks.
    public func record(_ identity: ProcessIdentity) throws {
        var staged = identities
        staged[identity.environmentID] = identity
        try persist(staged)
        identities = staged
    }

    public func remove(_ environment: EnvironmentID) throws {
        guard identities[environment] != nil else { return }
        var staged = identities
        staged.removeValue(forKey: environment)
        try persist(staged)
        identities = staged
    }

    private func persist(_ staged: [EnvironmentID: ProcessIdentity]) throws {
        let data: Data
        do {
            data = try encoder.encode(staged)
        } catch {
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "could not be encoded")
        }
        let temp = url.deletingLastPathComponent().appending(path: ".\(Self.fileName).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: temp)
        else {
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: "the state folder is not writable")
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: SanitizedText(error.localizedDescription, limit: 120).value)
        }
        guard rename(temp.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temp)
            throw ProcessIdentityStoreError.unwritable(path: url.path, reason: reason)
        }
    }
}

/// A process identity could not be persisted or read back. Either way a launched VM may be
/// running, so the outcome is unknown until the state is inspected.
public enum ProcessIdentityStoreError: Error, Hashable, Sendable, LocalizedError {
    case unwritable(path: String, reason: String)
    /// The record exists but could not be read or decoded; nothing it described can be
    /// trusted, and the service must not start VMs over ones it may have launched.
    case unreadable(path: String, reason: String)

    public var userMessage: String {
        switch self {
        case .unwritable(let path, let reason):
            "Guesthouse could not record the development Mac's process in \(GuesthouseError.sanitize(path, limit: 200)) (\(GuesthouseError.sanitize(reason))). The virtual machine may still be running; Guesthouse will inspect the actual state. Free disk space or check the storage location in Settings if this persists."
        case .unreadable(let path, let reason):
            "Guesthouse could not read its record of launched development Macs at \(GuesthouseError.sanitize(path, limit: 200)) (\(GuesthouseError.sanitize(reason))). A development Mac started earlier may still be running. Guesthouse will inspect the actual state before starting anything; if the file is damaged, move it aside and check again."
        }
    }

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unwritable: [.inspectState, .freeDiskSpace, .openSettings, .cancel]
        case .unreadable: [.inspectState, .openSettings, .cancel]
        }
    }
    public var errorDescription: String? { userMessage }
}
