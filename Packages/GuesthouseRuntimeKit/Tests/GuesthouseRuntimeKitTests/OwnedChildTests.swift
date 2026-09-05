import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct OwnedChildTests {
    private func spawn(
        _ executable: String = "/usr/bin/true", arguments: [String] = [],
        environment: [String: String] = [:], directory: PinnedWorkingDirectory? = nil,
        input: FileHandle? = nil, output: Pipe, error: Pipe,
        calls: OwnedChild.SystemCalls = .live
    ) throws -> OwnedChild {
        // Foundation's nullDevice handle is a Process sentinel, not a borrowable Darwin fd.
        let borrowedInput = try input ?? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        return try withExtendedLifetime((borrowedInput, output, error)) {
            try OwnedChild.spawn(executable: URL(fileURLWithPath: executable), arguments: arguments,
                             environment: environment, workingDirectory: directory,
                             standardInput: borrowedInput.fileDescriptor,
                             standardOutput: output.fileHandleForWriting.fileDescriptor,
                             standardError: error.fileHandleForWriting.fileDescriptor, calls: calls)
        }
    }

    /// Bounded, nonblocking EOF observation: leaked writer copies fail rather than hang.
    private func drain(_ pipe: Pipe, maximumBytes: Int = 4096) async throws -> Data {
        let fd = pipe.fileHandleForReading.fileDescriptor
        #expect(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0)
        let deadline = ContinuousClock.now + .seconds(2)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                try #require(result.count <= maximumBytes)
            } else {
                try #require(errno == EAGAIN || errno == EINTR)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        Issue.record("The owned spawn retained a pipe writer after exit or failure")
        return result
    }

    @Test func rapidExitIsObservedAndReapedExactlyOnce() async throws {
        for _ in 0..<20 {
            let reaps = Mutex(0)
            var calls = OwnedChild.SystemCalls.live
            calls.reap = { pid in reaps.withLock { $0 += 1 }; return OwnedChild.SystemCalls.live.reap(pid) }
            let child = try spawn(output: Pipe(), error: Pipe(), calls: calls)
            #expect(await child.waitForReapedExit() == .success(.status(0)))
            #expect(await child.waitForReapedExit() == .success(.status(0)))
            #expect(reaps.withLock { $0 } == 1)
            #expect(child.signal(SIGKILL) == .alreadyReaped)
        }
    }

    @Test func aCancelledWaiterDoesNotCancelOwnershipOrReaping() async throws {
        let input = Pipe(), output = Pipe(), error = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        let child = try spawn("/bin/cat", input: input.fileHandleForReading, output: output, error: error)
        #expect(getpgid(child.processIdentifier) == child.processIdentifier)
        #expect(getsid(child.processIdentifier) == child.processIdentifier)
        let waiter = Task { await child.waitForReapedExit() }
        waiter.cancel()
        #expect(child.signal(0) == .delivered)
        try input.fileHandleForWriting.close()
        #expect(await waiter.value == .success(.status(0)))
        #expect(child.signal(SIGTERM) == .alreadyReaped)
    }

    @Test func aDeliveredSignalIsFollowedByObservedReaping() async throws {
        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        let child = try spawn("/bin/cat", input: input.fileHandleForReading, output: Pipe(), error: Pipe())
        #expect(child.signal(SIGTERM) == .delivered)
        try input.fileHandleForWriting.close()
        #expect(await child.waitForReapedExit() == .success(.signal(SIGTERM)))
    }

    @Test func releasingEveryCallerStillKeepsTheReaperAlive() async throws {
        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        let (events, continuation) = AsyncStream.makeStream(of: Bool.self)
        var calls = OwnedChild.SystemCalls.live
        calls.reap = { pid in
            let result = OwnedChild.SystemCalls.live.reap(pid)
            continuation.yield(result == .success(.status(0)))
            continuation.finish()
            return result
        }
        var child: OwnedChild? = try spawn("/bin/cat", input: input.fileHandleForReading, output: Pipe(), error: Pipe(), calls: calls)
        weak let released = child
        child = nil
        #expect(released != nil)
        try input.fileHandleForWriting.close()
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == true)
        let deadline = ContinuousClock.now + .seconds(2)
        while released != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(released == nil)
    }

    @Test(arguments: [ECHILD, EIO])
    func waitErrorsPermanentlyWithdrawSignalAuthority(errorCode: Int32) async throws {
        let signals = Mutex(0), reaps = Mutex(0)
        var calls = OwnedChild.SystemCalls.live
        calls.waitForExit = { pid in
            // Simulate a competing targeted reaper: consume this actual short-lived fixture
            // before returning the injected authority error. No fixture is left unowned.
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            return .failure(.waitAuthorityLost(errorCode))
        }
        calls.reap = { _ in reaps.withLock { $0 += 1 }; return .failure(.waitAuthorityLost(ECHILD)) }
        calls.signal = { _, _ in signals.withLock { $0 += 1 }; return .delivered }
        let child = try spawn(output: Pipe(), error: Pipe(), calls: calls)
        #expect(await child.waitForReapedExit() == .failure(.waitAuthorityLost(errorCode)))
        #expect(child.signal(SIGKILL) == .authorityLost)
        #expect(child.signal(SIGTERM) == .authorityLost)
        #expect(signals.withLock { $0 } == 0)
        #expect(reaps.withLock { $0 } == 0)
    }

    @Test func anObservedExitStaysUnreapedUntilTheBlockingWaitReturns() async throws {
        let (events, continuation) = AsyncStream.makeStream(of: Bool.self)
        let release = DispatchSemaphore(value: 0), reaps = Mutex(0)
        defer { release.signal() }
        var calls = OwnedChild.SystemCalls.live
        calls.waitForExit = { pid in
            let observed = OwnedChild.SystemCalls.live.waitForExit(pid)
            continuation.yield(true)
            release.wait() // Only this dedicated dispatch waiter blocks, never an async task.
            return observed
        }
        calls.reap = { pid in
            reaps.withLock { $0 += 1 }
            return OwnedChild.SystemCalls.live.reap(pid)
        }
        let child = try spawn(output: Pipe(), error: Pipe(), calls: calls)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(child.signal(SIGKILL) == .alreadyExited)
        #expect(reaps.withLock { $0 } == 0)
        release.signal()
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(reaps.withLock { $0 } == 1)
        #expect(child.signal(SIGKILL) == .alreadyReaped)
    }

    @Test func aRenamedWorkingDirectoryCannotRedirectTheChild() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "owned-cwd-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "original"), moved = root.appending(path: "moved")
        let replacement = root.appending(path: "replacement")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: original.appending(path: "marker"))
        try Data("substituted".utf8).write(to: replacement.appending(path: "marker"))
        let pinned = try PinnedWorkingDirectory(original)
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: replacement)
        let output = Pipe(), error = Pipe()
        let child = try spawn("/bin/cat", arguments: ["marker"], directory: pinned, output: output, error: error)
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(try await drain(output) == Data("owned".utf8))
        #expect(try await drain(error).isEmpty)
        #expect(throws: OwnedChild.Failure.self) { try PinnedWorkingDirectory(original) }
    }

    @Test(arguments: [true, false])
    func spawnClosesOwnedCopiesButNotBorrowedStdio(succeed: Bool) async throws {
        let output = Pipe(), error = Pipe()
        if succeed {
            let child = try spawn(output: output, error: error)
            #expect(await child.waitForReapedExit() == .success(.status(0)))
        } else {
            #expect(throws: OwnedChild.Failure.systemCall("spawn", ENOENT)) {
                try spawn("/nonexistent-owned-child-fixture", output: output, error: error)
            }
        }
        #expect(fcntl(output.fileHandleForWriting.fileDescriptor, F_GETFD) >= 0)
        #expect(fcntl(error.fileHandleForWriting.fileDescriptor, F_GETFD) >= 0)
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
        #expect(try await drain(output).isEmpty)
        #expect(try await drain(error).isEmpty)
    }

    @Test func environmentIsExplicit() async throws {
        let output = Pipe(), error = Pipe()
        let child = try spawn("/usr/bin/env", environment: ["OWNED_FIXTURE": "present"], output: output, error: error)
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(try await drain(output) == Data("OWNED_FIXTURE=present\n".utf8))
        #expect(try await drain(error).isEmpty)
    }

    @Test func unrelatedDescriptorsAreClosedWhileTheChildIsStillAlive() async throws {
        let input = Pipe(), unrelated = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        #expect(fcntl(unrelated.fileHandleForWriting.fileDescriptor, F_SETFD, 0) == 0)
        let child = try spawn("/bin/cat", input: input.fileHandleForReading, output: Pipe(), error: Pipe())
        try unrelated.fileHandleForWriting.close()
        #expect(try await drain(unrelated).isEmpty)
        #expect(child.signal(0) == .delivered)
        try input.fileHandleForWriting.close()
        #expect(await child.waitForReapedExit() == .success(.status(0)))
    }

    @Test func ownedSpawnComposesWithBoundedReadersAndBothEOFs() async throws {
        let output = Pipe(), error = Pipe()
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessOutput.self)
        let truncated = Mutex(false)
        let readers = OutputReaders(continuation: continuation, maximumBytes: 128) { truncated.withLock { $0 = true } }
        defer { readers.detach(); continuation.finish() }
        try readers.attach(output.fileHandleForReading, kind: .stdout)
        try readers.attach(error.fileHandleForReading, kind: .stderr)
        let collector = Task { var bytes = 0; for await line in stream { bytes += line.line.text.utf8.count + 1 }; return bytes }
        let child = try spawn("/usr/bin/printf", arguments: ["%0200000d", "0"], output: output, error: error)
        try output.fileHandleForWriting.close()
        try error.fileHandleForWriting.close()
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        let drained = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: readers.waitUntilDrained(by: .now() + 2))
            }
        }
        #expect(drained == .success)
        continuation.finish()
        #expect(await collector.value <= 128)
        #expect(truncated.withLock { $0 })
    }

    @Test func invalidCStringsFailBeforeSpawning() {
        #expect(throws: OwnedChild.Failure.invalidInvocation) {
            try spawn(arguments: ["untrusted\0suffix"], output: Pipe(), error: Pipe())
        }
        #expect(throws: OwnedChild.Failure.invalidInvocation) {
            try spawn(environment: ["KEY=other": "value"], output: Pipe(), error: Pipe())
        }
    }
}
