import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct ProcessRunnerHardeningTests {
    let runner = ProcessRunner()

    func collect(_ run: ProcessRun) async -> (lines: [String], exit: ProcessExit) {
        var lines: [String] = []
        for await output in run.output { lines.append(output.line.text) }
        return (lines, await run.exit())
    }

    @Test func interruptedZeroExitsAreNotSuccesses() {
        #expect(ProcessExit(reason: .status(0)).succeeded)
        #expect(!ProcessExit(reason: .status(0), timedOut: true).succeeded)
        #expect(!ProcessExit(reason: .status(0), terminated: true).succeeded)
        #expect(!ProcessExit(reason: .status(0), standardInputFailed: true).succeeded)
        #expect(ProcessExit(reason: .status(0), outputTruncated: true).succeeded)
    }

    @Test func terminationAfterANaturalExitIsNotRecorded() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/true")))
        let first = await run.exit()
        run.terminate(gracePeriod: .milliseconds(10))
        run.timeOut(gracePeriod: .milliseconds(10))
        let second = await run.exit()
        #expect(first == second)
        #expect(!second.terminated && !second.timedOut)
    }

    @Test func aRunNobodyHoldsStillTimesOut() async throws {
        var run: ProcessRun? = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(100), terminationGracePeriod: .milliseconds(100)))
        let pid = try #require(run?.processIdentifier)
        run = nil
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(pid, 0) != 0, "the child was ended although its run was released")
    }

    @Test func descendantsAreTerminatedWithTheChild() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/caffeinate"), arguments: ["-i", "/bin/sleep", "30"], timeout: .seconds(30), terminationGracePeriod: .milliseconds(200)))
        var descendants: [pid_t] = []
        for _ in 0..<100 where descendants.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            descendants = ProcessRun.descendants(of: run.processIdentifier)
        }
        #expect(!descendants.isEmpty, "caffeinate should have spawned sleep")
        run.terminate(gracePeriod: .milliseconds(200))
        let exit = await run.exit()
        #expect(exit.terminated)
        for pid in descendants {
            for _ in 0..<50 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(kill(pid, 0) != 0, "descendant \(pid) survived")
        }
    }

    @Test func overlongRecordsAreSplitAndCarriageReturnsEndRecords() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%0200000d\rdone", "0"]))
        let result = await collect(run)
        #expect(result.exit.succeeded)
        #expect(result.lines.count >= 4)
        #expect(result.lines.allSatisfy { $0.utf8.count <= 64 << 10 })
        #expect(result.lines.last == "done")
        #expect(result.lines.dropLast().map { $0.utf8.count }.reduce(0, +) == 200_000)
        #expect(!result.exit.outputTruncated)
    }

    @Test func outputBeyondTheCapIsDiscardedAndReported() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/yes"), timeout: .milliseconds(400), terminationGracePeriod: .milliseconds(100), maximumOutputBytes: 8_000))
        let result = await collect(run)
        #expect(result.exit.outputTruncated)
        #expect(result.exit.timedOut)
        #expect(result.lines.map { $0.utf8.count }.reduce(0, +) <= 8_000 + 64)
    }

    @Test func undeliveredStandardInputIsReported() async throws {
        let big = Data(repeating: 0x41, count: 4 << 20)
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/true"), standardInput: .data(big), timeout: .seconds(10)))
        let exit = await run.exit()
        #expect(exit.reason == .status(0))
        #expect(exit.standardInputFailed)
        #expect(!exit.succeeded)
    }

    @Test func bareDeviceCodesInOutputAreRedacted() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["AB12-CD34"]))
        let result = await collect(run)
        #expect(result.lines == ["[redacted:device-code]"])
    }

    @Test func launchErrorsAreActionable() {
        for error in [ProcessLaunchError.executableNotFound("tart"), .launchFailed(executable: "tart", reason: SanitizedText("EPERM"))] {
            #expect(!error.userMessage.isEmpty)
            #expect(error.recoveryActions.first == .repair(.runtime))
            #expect(error.errorDescription == error.userMessage)
        }
    }
}
