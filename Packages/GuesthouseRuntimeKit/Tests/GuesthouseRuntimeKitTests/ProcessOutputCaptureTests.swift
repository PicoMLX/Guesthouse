import Darwin
import Foundation
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct ProcessOutputCaptureTests {
    @Test func commandResponseBytesAreUnchangedAndTransferredOnce() async throws {
        let stdout = Pipe(), stderr = Pipe()
        let readers = OutputReaders(maximumBytes: 1_024, capturing: [.stdout, .stderr])
        defer { readers.detach() }
        try readers.attach(stdout.fileHandleForReading, kind: .stdout)
        try readers.attach(stderr.fileHandleForReading, kind: .stderr)
        // Synthetic response data must remain parseable, not modified by text redaction.
        let original = Data("{\"code\":\"AB12-CD34\"}\r\n".utf8) + Data([0, 0xFF, 0xE2, 0x82, 0xAC])
        for byte in original { try stdout.fileHandleForWriting.write(contentsOf: Data([byte])) }
        try stderr.fileHandleForWriting.write(contentsOf: Data("failure\n".utf8))
        try stdout.fileHandleForWriting.close(); try stderr.fileHandleForWriting.close()
        #expect(readers.takeResponse() == nil) // Attachment is not sealed yet, even if EOF won.
        #expect(await awaitOutputDrain(readers) == .success)
        let response = try #require(readers.takeResponse())
        #expect(response.stdout == original && response.stderr == Data("failure\n".utf8))
        #expect(response.isComplete && !response.truncated)
        #expect(readers.takeResponse() == nil)
    }

    @Test(arguments: [Int.min, 0, 128, Int.max])
    func ownedSpawnComposesWithBoundedReadersAndBothEOFs(limit: Int) async throws {
        let readers = OutputReaders(maximumBytes: limit, capturing: [.stdout, .stderr])
        let response = try await printedResponse(readers)
        let expected = min(2_000_000, min(OutputReaders.captureCeiling, max(0, limit)))
        #expect(readers.maximumBytes == min(OutputReaders.captureCeiling, max(0, limit)))
        #expect(response.stdout.count == expected && response.stderr.isEmpty)
        #expect(response.stdoutEnd == .eof && response.stderrEnd == .eof)
        #expect(response.truncated == (expected < 2_000_000))
        #expect(response.isComplete == !response.truncated)
    }

    @Test(arguments: [false, true])
    func unneededOutputIsDrainedWithoutCaptureOrTruncation(captureOnlyStderr: Bool) async throws {
        let readers = captureOnlyStderr
            ? OutputReaders(maximumBytes: 128, capturing: [.stderr]) : OutputReaders()
        let response = try await printedResponse(readers)
        #expect(response.stdout.isEmpty && response.stderr.isEmpty)
        #expect(response.isComplete && !response.truncated)
    }

    @Test func bothStreamsShareTheSameByteBudgetIncludingNewlines() async throws {
        let stdout = Pipe(), stderr = Pipe()
        let readers = OutputReaders(maximumBytes: 5, capturing: [.stdout, .stderr])
        defer { readers.detach() }
        try readers.attach(stdout.fileHandleForReading, kind: .stdout)
        try readers.attach(stderr.fileHandleForReading, kind: .stderr)
        try stdout.fileHandleForWriting.write(contentsOf: Data(repeating: 10, count: 512))
        try stderr.fileHandleForWriting.write(contentsOf: Data(repeating: 10, count: 512))
        try stdout.fileHandleForWriting.close(); try stderr.fileHandleForWriting.close()
        #expect(await awaitOutputDrain(readers) == .success)
        let response = try #require(readers.takeResponse())
        #expect(response.stdout.count + response.stderr.count == 5)
        #expect(response.truncated && !response.isComplete)
        #expect(response.stdoutEnd == .eof && response.stderrEnd == .eof)
    }

    @Test func abandonedOrMissingPipesCannotLookComplete() async throws {
        let pipe = Pipe(), readers = OutputReaders()
        defer { try? pipe.fileHandleForWriting.close() }
        try readers.attach(pipe.fileHandleForReading, kind: .stdout)
        #expect(await awaitOutputDrain(readers, by: .now()) == .timedOut)
        let response = try #require(readers.takeResponse())
        #expect(response.stdoutEnd == .abandoned && response.stderrEnd == .notAttached)
        #expect(!response.isComplete)
        #expect(readers.takeResponse() == nil)
    }

    @Test func refusedAttachmentDoesNotConsumeABorrowedHandle() async throws {
        let first = Pipe(), refused = Pipe(), readers = OutputReaders()
        defer { readers.detach(); try? first.fileHandleForWriting.close(); try? refused.fileHandleForWriting.close() }
        try readers.attach(first.fileHandleForReading, kind: .stdout)
        #expect(throws: OutputReaders.Failure.duplicateStream) {
            try readers.attach(refused.fileHandleForReading, kind: .stdout)
        }
        #expect(throws: OutputReaders.Failure.duplicateStream) {
            try readers.attach(first.fileHandleForReading, kind: .stderr)
        }
        let alias = FileHandle(fileDescriptor: first.fileHandleForReading.fileDescriptor, closeOnDealloc: false)
        #expect(throws: OutputReaders.Failure.duplicateStream) { try readers.attach(alias, kind: .stderr) }
        readers.detach()
        #expect(throws: OutputReaders.Failure.closed) {
            try readers.attach(refused.fileHandleForReading, kind: .stderr)
        }
        #expect(fcntl(refused.fileHandleForReading.fileDescriptor, F_GETFD) >= 0)
        #expect(await awaitOutputDrain(readers) == .success)
    }

    /// Retains #108's real owned-spawn/reader composition, now without the redactor pipeline.
    private func printedResponse(_ readers: OutputReaders) async throws -> OutputReaders.Response {
        let stdout = Pipe(), stderr = Pipe()
        defer { readers.detach(); try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close() }
        try readers.attach(stdout.fileHandleForReading, kind: .stdout)
        try readers.attach(stderr.fileHandleForReading, kind: .stderr)
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let child = try OwnedChild.spawn(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%02000000d", "0"], standardInput: input.fileDescriptor,
            standardOutput: stdout.fileHandleForWriting.fileDescriptor,
            standardError: stderr.fileHandleForWriting.fileDescriptor)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)); if !Task.isCancelled { child.signal(SIGKILL) } }
            catch {} // A failed drain cannot leave this controlled fixture blocked forever.
        }
        defer { watchdog.cancel() }
        try stdout.fileHandleForWriting.close(); try stderr.fileHandleForWriting.close()
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(await awaitOutputDrain(readers) == .success)
        return try #require(readers.takeResponse())
    }
}
