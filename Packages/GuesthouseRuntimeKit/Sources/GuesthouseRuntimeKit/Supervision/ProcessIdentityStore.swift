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

    public init(directory: URL) throws {
        url = directory.appending(path: Self.fileName)
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(style.format(date))
        }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try style.parse(try decoder.singleValueContainer().decode(String.self))
        }
        if FileManager.default.fileExists(atPath: url.path) {
            identities = try decoder.decode([EnvironmentID: ProcessIdentity].self, from: try Data(contentsOf: url))
        } else {
            identities = [:]
        }
    }

    public var all: [EnvironmentID: ProcessIdentity] { identities }

    public func identity(for environment: EnvironmentID) -> ProcessIdentity? { identities[environment] }

    /// Records the identity durably. Returns only after the file is on disk.
    public func record(_ identity: ProcessIdentity) throws {
        identities[identity.environmentID] = identity
        try persist()
    }

    public func remove(_ environment: EnvironmentID) throws {
        guard identities.removeValue(forKey: environment) != nil else { return }
        try persist()
    }

    private func persist() throws {
        let data = try encoder.encode(identities)
        let temp = url.deletingLastPathComponent().appending(path: ".\(Self.fileName).tmp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
