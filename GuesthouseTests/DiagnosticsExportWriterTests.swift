import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import Guesthouse

@MainActor struct DiagnosticsExportWriterTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsWriter-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    @Test func newExportHasExactContentsAndPrivatePermissions() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Diagnostics", isDirectory: true)
        let export = try DiagnosticsExportBuilder.build(log: DiagnosticLog())
        let result = await DiagnosticsExportWriter.write(export, to: destination)
        guard case .success = result else { Issue.record("Expected export success"); return }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)) == Set(export.files.keys))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for (name, data) in export.files {
            let file = destination.appendingPathComponent(name)
            #expect(try Data(contentsOf: file) == data)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }
    @Test(arguments: [false, true]) func existingFolderOrSymlinkIsNeverReused(symlink: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("User work.txt"), contents = Data("keep this".utf8)
        try contents.write(to: marker)
        let destination: URL
        if symlink {
            destination = root.appendingPathComponent("Link")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: existing)
        } else { destination = existing }
        let result = await DiagnosticsExportWriter.write(try DiagnosticsExportBuilder.build(log: DiagnosticLog()), to: destination)
        guard case .failure(.destinationExists) = result else { Issue.record("Expected existing-destination refusal"); return }
        #expect(try Data(contentsOf: marker) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["User work.txt"])
    }
    @Test func partialFailureRemovesOnlyCompletedFilesAndNeverLeavesAManifest() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Diagnostics", isDirectory: true)
        let writes = Mutex(0)
        let result = await DiagnosticsExportWriter.write(try DiagnosticsExportBuilder.build(log: DiagnosticLog()), to: destination) { data, url in
            let count = writes.withLock { $0 += 1; return $0 }
            if count == 2 {
                try Data("partial".utf8).write(to: url)
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url)
        }
        guard case .failure(.writeFailed) = result else { Issue.record("Expected typed write failure"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["log.txt"])
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        #expect(!DiagnosticsExportWriter.Failure.writeFailed.userMessage.isEmpty)
        #expect(!DiagnosticsExportWriter.Failure.writeFailed.recoveryActions.isEmpty)
    }
    @Test func failedFinalWriteCannotLeaveACompletionManifest() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Diagnostics", isDirectory: true)
        let result = await DiagnosticsExportWriter.write(try DiagnosticsExportBuilder.build(log: DiagnosticLog()), to: destination) { data, url in
            try data.write(to: url)
            if url.lastPathComponent == "manifest.json" { throw CocoaError(.fileWriteNoPermission) }
        }
        guard case .failure(.writeFailed) = result else { Issue.record("Expected typed write failure"); return }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    @Test func nonexistentParentDoesNotCreateUnselectedDirectories() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Missing", isDirectory: true)
        let result = await DiagnosticsExportWriter.write(try DiagnosticsExportBuilder.build(log: DiagnosticLog()), to: parent.appendingPathComponent("Export"))
        guard case .failure(.destinationUnavailable) = result else { Issue.record("Expected inaccessible destination"); return }
        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }
}
