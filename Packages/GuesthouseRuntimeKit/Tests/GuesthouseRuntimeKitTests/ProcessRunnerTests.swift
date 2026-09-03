import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.serialized) struct ProcessRunnerTests {
    let runner = ProcessRunner()

    func collect(_ run: ProcessRun) async -> (lines: [ProcessOutput], exit: ProcessExit) {
        var lines: [ProcessOutput] = []
        for await line in run.output { lines.append(line) }
        return (lines, await run.exit())
    }

    @Test func echoStreamsStdoutAndExitsZero() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello", "world"]))
        let result = await collect(run)
        #expect(result.lines == [.stdout(RedactedLine(literal: "hello world"))])
        #expect(result.exit == ProcessExit(reason: .status(0)))
        #expect(result.exit.succeeded)
    }

    @Test func stderrIsTaggedAndNonZeroStatusIsReported() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/ls"), arguments: ["/definitely/not/here"]))
        let result = await collect(run)
        #expect(result.lines.count == 1)
        guard case .stderr(let line) = result.lines[0] else { Issue.record("expected stderr"); return }
        #expect(line.text.contains("No such file"))
        #expect(result.exit.reason == .status(1))
        #expect(!result.exit.succeeded)
    }

    @Test func timeoutTerminatesWithinTheGracePeriod() async throws {
        let started = ContinuousClock.now
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], timeout: .milliseconds(200), terminationGracePeriod: .milliseconds(300)))
        let result = await collect(run)
        #expect(result.exit.timedOut)
        #expect(result.exit.reason == .signal(SIGTERM))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func largeOutputIsDrainedWithoutDeadlock() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/yes"), timeout: .milliseconds(400), terminationGracePeriod: .milliseconds(200)))
        var count = 0
        for await _ in run.output { count += 1 }
        let exit = await run.exit()
        #expect(count > 10_000, "read \(count) lines")
        #expect(exit.timedOut)
    }

    @Test func environmentIsExplicitNotInherited() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/env"), environment: ["GUESTHOUSE_TEST": "1"]))
        let result = await collect(run)
        let text = result.lines.map(\.line.text)
        #expect(text == ["GUESTHOUSE_TEST=1"])
        #expect(!text.contains { $0.hasPrefix("HOME=") || $0.hasPrefix("PATH=") })
    }

    @Test func terminateRequestEndsTheProcess() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], timeout: .seconds(30)))
        run.terminate(gracePeriod: .milliseconds(200))
        let result = await collect(run)
        #expect(result.exit.terminated)
        #expect(!result.exit.timedOut)
        #expect(result.exit.reason == .signal(SIGTERM))
    }

    @Test func outputIsRedactedBeforeItLeavesTheRunner() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["token", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab", "done"]))
        let result = await collect(run)
        #expect(result.lines.map(\.line.text) == ["token [redacted:github-token] done"])
    }

    @Test func standardInputIsDelivered() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/cat"), standardInput: .data(Data("first\nsecond".utf8))))
        let result = await collect(run)
        #expect(result.lines.map(\.line.text) == ["first", "second"])
        #expect(result.exit.succeeded)
    }

    @Test func missingExecutableFailsBeforeLaunch() async {
        await #expect(throws: ProcessLaunchError.executableNotFound("nope")) {
            _ = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/nope")))
        }
    }

    @Test func workingDirectoryIsHonored() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/pwd"), currentDirectory: URL(fileURLWithPath: "/private/tmp")))
        let result = await collect(run)
        #expect(result.lines.map(\.line.text) == ["/private/tmp"])
    }
}
