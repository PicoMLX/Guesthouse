import Darwin
import Foundation
import GuesthouseCore

/// GUI-only, explicit save-panel export. Never used for runtime storage or provider files.
nonisolated enum DiagnosticsExportWriter {
    enum Failure: Error, Equatable, Sendable {
        case destinationUnavailable, destinationExists, writeFailed
        var userMessage: String {
            switch self {
            case .destinationUnavailable: "Guesthouse could not access the selected export location."
            case .destinationExists: "That export destination already exists. Choose a new folder name."
            case .writeFailed: "Guesthouse could not save a complete diagnostic export."
            }
        }
        var recoveryMessage: String {
            let partial = self == .writeFailed ? "An incomplete export folder may remain at the selected location. Inspect it and remove partial files if they are no longer needed. " : ""
            return partial + "Check the selected location and available space, then save with a new folder name. No existing export is replaced."
        }
        var recoveryActions: [RecoveryAction] { [.chooseAllowedLocation, .cancel] }
    }

    /// Acquire scoped access for the complete write. A false scope result is not itself a
    /// denial (app-container/test locations need no grant); sandboxed file I/O enforces access.
    /// Only a new directory is accepted. Write the manifest last so incomplete files cannot
    /// appear to be a complete bundle. Roll back our completed files, never recursively delete
    /// unexpected contents. A partial failed write may require user inspection.
    @concurrent static func write(_ export: DiagnosticsExport, to destination: URL,
        writeFile: @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }) async -> Result<Void, Failure> {
        guard destination.isFileURL else { return .failure(.destinationUnavailable) }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        guard mkdir(destination.path, 0o700) == 0 else {
            return .failure(errno == EEXIST ? .destinationExists : .destinationUnavailable)
        }
        var written: [URL] = []
        do {
            for name in ["diagnostics.json", "log.txt", "excluded.txt", "manifest.json"] {
                guard let data = export.files[name] else { throw Failure.writeFailed }
                let url = destination.appendingPathComponent(name, isDirectory: false)
                try writeFile(data, url)
                written.append(url)
            }
            return .success(())
        } catch {
            // Never leave a completion marker after a failed final write or permission update.
            try? FileManager.default.removeItem(at: destination.appendingPathComponent("manifest.json"))
            for url in written { try? FileManager.default.removeItem(at: url) }
            _ = rmdir(destination.path) // Fails safely if any unexpected/partial content remains.
            return .failure(.writeFailed)
        }
    }
}
