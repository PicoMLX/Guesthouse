import Darwin
import Foundation
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct ProcessOutputCleanupTests {
    /// Check the kernel's pipe ownership without inspecting a closed FileHandle or a saved
    /// fd number that another parallel test may have reused. Suppress SIGPIPE only here.
    private func expectNoReaders(_ pipe: Pipe, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let writer = pipe.fileHandleForWriting.fileDescriptor
        try #require(fcntl(writer, F_SETNOSIGPIPE, 1) == 0)
        var byte: UInt8 = 0
        // Foundation's cancelled readiness source can briefly hold a duplicated descriptor
        // after FileHandle.close returns. Wait for that asynchronous cancellation too.
        for _ in 0..<100 {
            let written = Darwin.write(writer, &byte, 1)
            let code = errno
            if written == -1, code == EPIPE { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The pipe still has a reader after cancellation", sourceLocation: sourceLocation)
    }

    @Test func aDrainTimeoutClosesBothReadersWhileWritersRemainOpen() async throws {
        let stdout = Pipe()
        let stderr = Pipe()
        defer {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        let (_, continuation) = AsyncStream.makeStream(of: ProcessOutput.self)
        let readers = OutputReaders(continuation: continuation, maximumBytes: 1_024, truncated: {})
        try readers.attach(stdout.fileHandleForReading, kind: .stdout)
        try readers.attach(stderr.fileHandleForReading, kind: .stderr)

        #expect(readers.waitUntilDrained(by: .now()) == .timedOut)
        #expect(stdout.fileHandleForReading.readabilityHandler == nil)
        #expect(stderr.fileHandleForReading.readabilityHandler == nil)
        try await expectNoReaders(stdout)
        try await expectNoReaders(stderr)
        #expect(readers.waitUntilDrained(by: .now()) == .success)
    }

    @Test func endOfFileRemovesItsHandlerAndCompletesTheDrain() throws {
        let pipe = Pipe()
        let (_, continuation) = AsyncStream.makeStream(of: ProcessOutput.self)
        let readers = OutputReaders(continuation: continuation, maximumBytes: 1_024, truncated: {})
        try readers.attach(pipe.fileHandleForReading, kind: .stdout)
        try pipe.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
        try pipe.fileHandleForWriting.close()

        #expect(readers.waitUntilDrained(by: .now() + .seconds(2)) == .success)
        #expect(pipe.fileHandleForReading.readabilityHandler == nil)
    }

    @Test(arguments: [false, true])
    func staleReadCallbacksAndConcurrentDetachCloseOnlyOnce(endOfFile: Bool) async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let (_, continuation) = AsyncStream.makeStream(of: ProcessOutput.self)
        let readers = OutputReaders(continuation: continuation, maximumBytes: 1_024, truncated: {})
        try readers.attach(pipe.fileHandleForReading, kind: .stdout)
        let queuedCallback = try #require(pipe.fileHandleForReading.readabilityHandler)
        if endOfFile { try pipe.fileHandleForWriting.close() }

        // Exercise an already queued callback even after cancellation, including a stale
        // readiness notification with no bytes available. Neither may read a reused fd or
        // leave the drain group a second time when EOF and detach overlap.
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index.isMultiple(of: 2) {
                queuedCallback(pipe.fileHandleForReading)
            } else {
                readers.detach()
            }
        }
        #expect(readers.waitUntilDrained(by: .now()) == .success)
        #expect(pipe.fileHandleForReading.readabilityHandler == nil)
        if !endOfFile { try await expectNoReaders(pipe) }
    }

    @Test func releasingReadersDetachesAnOpenPipe() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let (_, continuation) = AsyncStream.makeStream(of: ProcessOutput.self)
        weak var released: OutputReaders?
        do {
            let readers = OutputReaders(continuation: continuation, maximumBytes: 1_024, truncated: {})
            try readers.attach(pipe.fileHandleForReading, kind: .stdout)
            released = readers
        }

        #expect(released == nil)
        #expect(pipe.fileHandleForReading.readabilityHandler == nil)
        try await expectNoReaders(pipe)
    }
}
