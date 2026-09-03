import Foundation
import GuesthouseCore

/// Writes a diagnostics bundle where the user chose to put it. The bundle itself is built in
/// GuesthouseCore; the host write happens here, in the app, under the save panel's grant.
enum DiagnosticsExportWriter {
    /// Writes the bundle as a folder. Existing files of the same names are replaced.
    static func write(_ export: DiagnosticsExport, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in export.files {
            try file.contents.write(to: directory.appending(path: file.name), options: .atomic)
        }
    }
}
