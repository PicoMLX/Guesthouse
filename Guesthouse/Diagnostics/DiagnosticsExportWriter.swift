import Foundation
import GuesthouseCore

/// Writes a diagnostics bundle where the user chose to put it. The bundle itself is built in
/// GuesthouseCore; the host write happens here, in the app, under the save panel's grant.
enum DiagnosticsExportWriter {
    /// Writes the bundle as a folder of its own.
    ///
    /// A destination that already holds something is refused rather than written into.
    /// `createDirectory` does not apply its attributes to a directory that exists, so a
    /// repeated export would leave the folder world-traversable; and the user shares whatever
    /// the folder contains, so unrelated files sitting beside the three would travel with the
    /// bundle the UI presented as a diagnostics export (MVP-PLAN.md §3 "Local storage").
    /// Nothing of the user's is deleted or moved on their behalf: they choose another location.
    ///
    /// A write that fails part way takes its own files back out again. Otherwise the folder
    /// holds a manifest with no log — which still reads as an export — and the emptiness guard
    /// above then refuses the retry to the same folder the save panel just offered.
    ///
    /// `writeFile` exists so that partial failure can be tested: the three names are fixed and
    /// the destination is checked empty first, so there is no way to make the second write fail
    /// from outside.
    static func write(
        _ export: DiagnosticsExport,
        to directory: URL,
        writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) throws {
        let directoryWasCreated: Bool
        if FileManager.default.fileExists(atPath: directory.path) {
            let existing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard existing.isEmpty else {
                throw GuesthouseError.runtimeStorageUnavailable(
                    reason: SanitizedText("the chosen folder is not empty"),
                    problem: .unsafeLocation
                )
            }
            // The folder was made by someone else, with whatever mode they chose.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            directoryWasCreated = false
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directoryWasCreated = true
        }
        var written: [URL] = []
        do {
            for file in export.files {
                let destination = directory.appending(path: file.name)
                try writeFile(file.contents, destination)
                written.append(destination)
            }
        } catch {
            for file in written { try? FileManager.default.removeItem(at: file) }
            // A folder the user already had stays, emptied of this attempt; one this attempt
            // made goes with it, so a failed export leaves the destination as it found it.
            if directoryWasCreated { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
}
