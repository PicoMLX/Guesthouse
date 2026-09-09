import Darwin
import Foundation
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct ProcessRunnerTests {
    let runner = ProcessRunner()
    let stdout: Set<OutputReaders.Kind> = [.stdout]

    @Test func knownResponseParsesUnmodifiedTemporaryInput() async throws {
        struct Reply: Decodable { let value: String }
        let data = Data(#"{"value":"temporary-response"}"#.utf8)
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/cat"),
            standardInput: .data(data), maximumOutputBytes: 4096, capturing: stdout))
        let report = try await run.waitForExit()
        #expect(try report.childExit?.get() == .status(0))
        #expect(report.input == .delivered && report.inputClosed && report.outputComplete)
        #expect(report.descendantScopeUnproven) // Parsing/exit success is not mutation proof.
        let response = try #require(await run.takeOutput())
        #expect(try JSONDecoder().decode(Reply.self, from: response.stdout).value == "temporary-response")
        #expect(await run.takeOutput() == nil)
    }

    @Test(arguments: [0, 128, 4 << 20])
    func stdinDeliveryAndEOF(_ count: Int) async throws {
        let bytes = Data(repeating: 65, count: count)
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/cat"),
            standardInput: .data(bytes), maximumOutputBytes: 4 << 20, capturing: stdout))
        let report = try await run.waitForExit()
        #expect(try report.childExit?.get() == .status(0))
        #expect(report.input == .delivered && report.inputClosed)
        #expect(try #require(await run.takeOutput()).stdout == bytes)
    }

    @Test func stderrAndFailureAreNotDiagnosticText() async throws {
        let marker = "guesthouse-missing-" + UUID().uuidString
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/ls"),
            arguments: ["/private/tmp/" + marker], maximumOutputBytes: 4096, capturing: [.stderr]))
        let report = try await run.waitForExit()
        #expect(try report.childExit?.get() == .status(1))
        #expect(report.outputComplete)
        let response = try #require(await run.takeOutput())
        #expect(response.stdout.isEmpty)
        #expect(String(decoding: response.stderr, as: UTF8.self).contains(marker))
        #expect(!ProcessLaunchFailure.executableUnavailable.message.contains(marker))
    }

    @Test func environmentAndWorkingDirectoryAreExplicit() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/env"),
            environment: ["GUESTHOUSE_TEST": "1"], maximumOutputBytes: 4096, capturing: stdout))
        _ = try await run.waitForExit()
        #expect(try #require(await run.takeOutput()).stdout == Data("GUESTHOUSE_TEST=1\n".utf8))
        let pwd = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/pwd"),
            currentDirectory: URL(fileURLWithPath: "/private/tmp"), maximumOutputBytes: 4096, capturing: stdout))
        _ = try await pwd.waitForExit()
        #expect(try #require(await pwd.takeOutput()).stdout == Data("/private/tmp\n".utf8))
    }

    @Test func largeOutputKeepsDrainingAfterCaptureSaturates() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%02000000d", "0"], maximumOutputBytes: 128, capturing: stdout))
        let report = try await run.waitForExit()
        #expect(try report.childExit?.get() == .status(0))
        #expect(!report.outputComplete && !report.timedOut)
        let response = try #require(await run.takeOutput())
        #expect(response.stdout.count == 128 && response.truncated)
        #expect(response.stdoutEnd == .eof && response.stderrEnd == .eof)
    }

    @Test(arguments: [false, true]) func unreadInputCannotBlockDeadline(_ supplyInput: Bool) async throws {
        let began = ContinuousClock.now
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"], standardInput: supplyInput ? .data(Data(repeating: 65, count: 4 << 20)) : .none,
            timeout: .milliseconds(100), terminationGracePeriod: .milliseconds(100)))
        let report = try await run.waitForExit()
        #expect(report.timedOut && !report.canceled)
        #expect(try report.childExit?.get() == .signal(SIGTERM))
        if supplyInput { #expect(report.input != .delivered) }
        #expect(ContinuousClock.now - began < .seconds(3))
    }

    @Test func earlyExitReportsUndeliveredInput() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/true"),
            standardInput: .data(Data(repeating: 65, count: 4 << 20))))
        let report = try await run.waitForExit()
        #expect(try report.childExit?.get() == .status(0))
        #expect(report.input != .delivered && report.inputClosed)
    }

    @Test func canceledWaitStillObservesReapedChild() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"], terminationGracePeriod: .milliseconds(50)))
        let waiting = Task { try await run.waitForExit() }
        waiting.cancel()
        let report = try await waiting.value
        #expect(report.canceled && !report.timedOut)
        #expect(try report.childExit?.get() == .signal(SIGTERM))
    }

    @Test func completedOutcomeCannotBeRewritten() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/true")))
        let first = try await run.waitForExit()
        await run.terminate(gracePeriod: .zero)
        let second = try await run.waitForExit()
        #expect(!first.canceled && !second.canceled && !second.timedOut)
        #expect(try second.childExit?.get() == .status(0))
    }

    @Test func timeoutAfterRootExitAbandonsInheritedPipes() async throws {
        let fixture = try Fixture(executable: "/usr/bin/true")
        defer { fixture.closeWriters() }
        let run = ProcessRun(child: fixture.child, readers: fixture.readers, input: nil, grace: .zero)
        await run.start(deadline: .now + .milliseconds(100), input: nil)
        let report = try await run.waitForExit()
        #expect(try report.childExit?.get() == .status(0))
        #expect(report.timedOut && !report.outputComplete && report.descendantScopeUnproven)
    }

    @Test func droppedFacadePreservesItsDeadline() async throws {
        let fixture = try Fixture()
        defer { fixture.closeWriters() }
        var run: ProcessRun? = ProcessRun(child: fixture.child, readers: fixture.readers, input: nil, grace: .zero)
        weak let facade = run
        await run?.start(deadline: .now + .milliseconds(100), input: nil)
        run = nil
        #expect(facade == nil)
        #expect(try await fixture.child.waitForReapedExit().get() == .signal(SIGTERM))
    }

    @Test func concurrentTerminationShortensOneEscalation() async throws {
        // Signal spy only affects our direct fixture; real SIGKILL still uses owned authority.
        let storage = SignalStorage()
        var calls = OwnedChild.SystemCalls.live
        calls.signal = { pid, signal in
            storage.signals.withLock { $0.append(signal) }
            return signal == SIGTERM ? .delivered : OwnedChild.SystemCalls.live.signal(pid, signal)
        }
        let fixture = try Fixture(calls: calls)
        defer { fixture.closeWriters() }
        let run = ProcessRun(child: fixture.child, readers: fixture.readers, input: nil, grace: .zero)
        await run.start(deadline: .now + .seconds(10), input: nil)
        await run.terminate(gracePeriod: .seconds(60))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { await run.terminate(gracePeriod: .milliseconds(50)) } }
        }
        #expect(try await fixture.child.waitForReapedExit().get() == .signal(SIGKILL))
        fixture.closeWriters()
        let report = try await run.waitForExit()
        #expect(report.canceled && !report.timedOut)
        #expect(storage.signals.withLock { $0 } == [SIGTERM, SIGKILL])
    }

    @Test func invalidOptionsAndLaunchFailuresAreFixedAndActionable() async throws {
        let cases: [(ProcessInvocation, ProcessLaunchFailure)] = [
            (.init(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: .seconds(-1)), .invalidOptions),
            (.init(executable: URL(fileURLWithPath: "/usr/bin/true"), standardInput: .data(Data(count: (4 << 20) + 1))), .invalidOptions),
            (.init(executable: URL(fileURLWithPath: "/guesthouse-missing-tool")), .executableUnavailable),
            (.init(executable: URL(fileURLWithPath: "/usr/bin/true"), currentDirectory: URL(fileURLWithPath: "/guesthouse-missing-folder")), .workingDirectoryUnavailable)
        ]
        for (invocation, failure) in cases {
            await #expect(throws: failure) { _ = try await runner.run(invocation) }
            #expect(!failure.message.isEmpty && !failure.recoveryActions.isEmpty)
            #expect(!failure.message.contains(invocation.executable.path))
        }
    }

    @Test func refusedKillReportsUnconfirmedExitWithoutRewritingItLater() async throws {
        let storage = SignalStorage()
        var calls = OwnedChild.SystemCalls.live
        calls.signal = { pid, signal in
            storage.allow.withLock { $0 } ? OwnedChild.SystemCalls.live.signal(pid, signal) : .refused(EPERM)
        }
        let fixture = try Fixture(calls: calls)
        defer { storage.allow.withLock { $0 = true }; fixture.closeWriters() }
        let run = ProcessRun(child: fixture.child, readers: fixture.readers, input: nil, grace: .zero)
        await run.start(deadline: .now, input: nil)
        let report = try await run.waitForExit()
        #expect(report.childExit == nil && report.timedOut && report.terminationRefused)
        #expect(!report.outputComplete && report.descendantScopeUnproven)
        storage.allow.withLock { $0 = true }
        #expect(fixture.child.signal(SIGKILL) == .delivered)
        #expect(try await fixture.child.waitForReapedExit().get() == .signal(SIGKILL))
        #expect(try await run.waitForExit().childExit == nil)
    }

    @Test func alreadyCanceledTaskDoesNotLaunch() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: ProcessLaunchFailure.canceled) {
                _ = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/true")))
            }
        }
        await task.value
    }

    private final class SignalStorage: Sendable {
        let signals = Mutex<[Int32]>([])
        let allow = Mutex(false)
    }
    private struct Fixture {
        let child: OwnedChild, readers = OutputReaders()
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        let watchdog: Task<Void, Never>
        init(executable: String = "/bin/cat", calls: OwnedChild.SystemCalls = .live) throws {
            try readers.attach(stdout.fileHandleForReading, kind: .stdout)
            try readers.attach(stderr.fileHandleForReading, kind: .stderr)
            let child = try OwnedChild.spawn(executable: URL(fileURLWithPath: executable),
                standardInput: stdin.fileHandleForReading.fileDescriptor,
                standardOutput: stdout.fileHandleForWriting.fileDescriptor,
                standardError: stderr.fileHandleForWriting.fileDescriptor, calls: calls)
            self.child = child
            watchdog = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                child.signal(SIGKILL)
            }
            try stdin.fileHandleForReading.close()
        }
        func closeWriters() {
            watchdog.cancel()
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            try? stdin.fileHandleForWriting.close()
        }
    }
}
