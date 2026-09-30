import Foundation
import GuesthouseClientKit
import GuesthouseCore
import Testing
@testable import Guesthouse

struct XcodeSelectionReadTests {
    @Test func unusableSelectionsFailBeforeRuntimeInspection() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-picker-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appending(path: "plain-file.app")
        try Data().write(to: file)
        let link = base.appending(path: "linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        for url in [URL(string: "https://example.invalid/Xcode.app")!, file, link, base.appending(path: "missing.app")] {
            #expect(await XcodeSelectionRead.run(url: url) == .failure(.selection(.unavailable)))
        }
    }

    @Test func cancellationBeforeSelectionDoesNotOpenTheURL() async {
        let (gate, resume) = AsyncStream<Void>.makeStream()
        defer { resume.finish() }
        let task = Task {
            for await _ in gate { break }
            return await XcodeSelectionRead.run(url: URL(filePath: "/unavailable/Xcode.app"))
        }
        task.cancel()
        #expect(await task.value == .failure(.canceled))
    }
}
