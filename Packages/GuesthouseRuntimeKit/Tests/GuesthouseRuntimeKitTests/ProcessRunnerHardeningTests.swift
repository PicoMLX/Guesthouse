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

    @Test func splitterKeepsCRLFAcrossReadsAndNeverCutsTokensOrScalars() {
        var splitter = RecordSplitter()
        var records = splitter.consume(Data("one\r".utf8))
        records += splitter.consume(Data("\ntwo\r\nthree".utf8))
        records += [splitter.flush()].compactMap { $0 }
        #expect(records.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", "three"])

        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let filler = String(repeating: "x", count: RecordSplitter.maximumRecordBytes - 20)
        var straddling = RecordSplitter()
        var chunks = straddling.consume(Data((filler + " " + token + " tail").utf8))
        chunks += [straddling.flush()].compactMap { $0 }
        let texts = chunks.map { String(decoding: $0, as: UTF8.self) }
        #expect(texts.contains { $0.contains(token) }, "the token is whole in one record")
        #expect(texts.allSatisfy { $0.utf8.count <= RecordSplitter.maximumRecordBytes })

        var multibyte = RecordSplitter()
        let ascii = String(repeating: "y", count: RecordSplitter.maximumRecordBytes - 1)
        var pieces = multibyte.consume(Data((ascii + "😀 end").utf8))
        pieces += [multibyte.flush()].compactMap { $0 }
        #expect(pieces.map { String(decoding: $0, as: UTF8.self) }.joined() == ascii + "😀 end", "no scalar was torn")
    }

    @Test func aTokenStraddlingAForcedSplitIsStillRedacted() async throws {
        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let filler = String(repeating: "x", count: RecordSplitter.maximumRecordBytes - 20)
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s %s tail", filler, token]))
        let result = await collect(run)
        #expect(!result.lines.joined().contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(result.lines.joined().contains("[redacted:github-token]"))
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

    @Test func aLongTokenFarFromTheLastSeparatorIsNotCut() {
        var splitter = RecordSplitter()
        var input = Data(repeating: UInt8(ascii: "a"), count: 60 << 10)
        input.append(UInt8(ascii: " "))
        let token = Data(repeating: UInt8(ascii: "t"), count: 6 << 10)
        input.append(token)
        input.append(UInt8(ascii: "\n"))
        let records = splitter.consume(input)
        #expect(records.count == 2)
        #expect(records.first?.count == 60 << 10)
        #expect(records.last == Data([UInt8(ascii: " ")]) + token, "the cut goes back to the separator, however far it is, and the separator leads what follows")
    }

    @Test func aHeaderValueTornFromItsLabelIsStillRedacted() {
        var splitter = RecordSplitter()
        // The forced cut lands exactly on the space between the label and its value.
        let filler = String(repeating: "x", count: RecordSplitter.maximumRecordBytes - 16)
        let records = splitter.consume(Data("\(filler) Authorization: opaque-secret\n".utf8))
        #expect(records.count == 2)
        #expect(String(decoding: records[1], as: UTF8.self) == " opaque-secret")

        let redactor = Redactor()
        var state = Redactor.StreamState()
        let texts = records.map { redactor.redact(processOutputLine: String(decoding: $0, as: UTF8.self), state: &state).text }
        #expect(!texts.contains { $0.contains("opaque-secret") }, "the value is a folded continuation of the label it was cut from")
        #expect(texts.last == "[redacted:authorization]")
    }

    @Test func aSignalIsWithheldWhenThePIDIsNoLongerTheCapturedProcess() {
        let me = getpid()
        #expect(ProcessRun.signalIfUnchanged(0, to: me, startedAt: ProcessRun.startTime(of: me)))
        // A start time that is not this process's stands for a PID the kernel handed on after
        // the captured process exited; signaling it would hit whoever holds it now.
        #expect(!ProcessRun.signalIfUnchanged(0, to: me, startedAt: Date(timeIntervalSince1970: 1)))
        #expect(!ProcessRun.signalIfUnchanged(0, to: me, startedAt: nil))
    }

    @Test func theGracePeriodOutlivesAParentThatExitsOnTheSignal() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/caffeinate"), arguments: ["-i", "/bin/sleep", "30"], timeout: .seconds(30), terminationGracePeriod: .seconds(1)))
        for _ in 0..<100 where ProcessRun.descendants(of: run.processIdentifier).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        run.terminate(gracePeriod: .seconds(1))
        #expect(await run.exit().terminated)
        // caffeinate exits on SIGTERM at once. A helper of its own that is still stopping has
        // the rest of the second before it is killed, and the parent's exit must not take it.
        let due = try #require(run.escalationDeadline, "the parent's exit cancelled the helpers' grace period")
        #expect(due > ContinuousClock.now)
        for _ in 0..<300 where run.escalationDeadline != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(run.escalationDeadline == nil, "the escalation still runs when the grace period ends")
    }

    @Test func theInvocationDeadlineShortensAnOpenEndedTermination() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], timeout: .seconds(30), terminationGracePeriod: .milliseconds(200)))
        // Stopping the child first keeps it from finishing its exit between the two requests,
        // so the second one meets a termination that is genuinely still under way.
        #expect(kill(run.processIdentifier, SIGSTOP) == 0)
        let began = run.stop(gracePeriod: .seconds(3600), becauseOfTimeout: false)
        let asked = run.escalationDeadline
        let second = run.stop(gracePeriod: .milliseconds(200), becauseOfTimeout: true)
        let enforced = run.escalationDeadline
        #expect(began)
        #expect(!second, "the deadline joins the termination under way instead of starting another")
        #expect(try #require(enforced) < #require(asked), "an invocation cannot be stretched past its own deadline by the grace period a caller asked for")
        let exit = await run.exit()
        #expect(exit.timedOut)
        #expect(exit.terminated)
    }

    @Test func overlappingTerminationRequestsBeginOneEscalation() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/caffeinate"), arguments: ["-i", "/bin/sleep", "30"], timeout: .seconds(30), terminationGracePeriod: .milliseconds(200)))
        // A process graph makes the scan that precedes the signals long enough for two
        // requests to overlap inside it.
        for _ in 0..<100 where ProcessRun.descendants(of: run.processIdentifier).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let begun = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<16 {
                group.addTask { run.stop(gracePeriod: .milliseconds(200), becauseOfTimeout: false) }
            }
            var count = 0
            for await began in group where began { count += 1 }
            return count
        }
        #expect(begun == 1, "only one request may own the termination of one process graph")
        #expect(await run.exit().terminated)
    }

    @Test func newlineOnlyOutputStillReachesTheCap() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [""], timeout: .milliseconds(400), terminationGracePeriod: .milliseconds(100), maximumOutputBytes: 500))
        let result = await collect(run)
        #expect(result.exit.outputTruncated)
        #expect(result.lines.allSatisfy { $0.isEmpty })
        // Each record costs at least the ending that closed it, so a 500 byte cap admits at
        // most 500 of them however long the child keeps printing.
        #expect(result.lines.count <= 500, "\(result.lines.count) empty records passed a 500 byte cap")
    }

    @Test func aMissingWorkingDirectoryIsItsOwnFailure() async {
        await #expect(throws: ProcessLaunchError.workingDirectoryUnavailable("here")) {
            _ = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/pwd"), currentDirectory: URL(fileURLWithPath: "/definitely/not/here")))
        }
    }

    @Test func anUnfinishedScalarAtTheLimitWaitsForTheNextRead() {
        var splitter = RecordSplitter()
        var input = Data(repeating: UInt8(ascii: "a"), count: RecordSplitter.maximumRecordBytes - 1)
        input.append(0xE2)
        let first = splitter.consume(input)
        #expect(first.count == 1)
        #expect(first.first?.count == RecordSplitter.maximumRecordBytes - 1)
        var rest = Data([0x82, 0xAC])
        rest.append(UInt8(ascii: "\n"))
        #expect(splitter.consume(rest) == [Data([0xE2, 0x82, 0xAC])])
    }

    @Test func outputAfterTheConsumerStopsListeningIsReportedTruncated() async throws {
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: .seconds(20)))
        await Task { for await _ in run.output { break } }.value
        try await Task.sleep(for: .milliseconds(100))
        run.terminate(gracePeriod: .milliseconds(200))
        let exit = await run.exit()
        #expect(exit.outputTruncated, "lines the stream no longer accepted are missing from what the awaiting owner saw")
    }

    @Test func launchErrorsAreActionable() {
        for error in [ProcessLaunchError.executableNotFound("tart"), .launchFailed(executable: "tart", reason: SanitizedText("EPERM"))] {
            #expect(!error.userMessage.isEmpty)
            #expect(error.recoveryActions.first == .repair(.runtime))
            #expect(error.errorDescription == error.userMessage)
        }
        // A workspace folder that is gone is not repaired by reinstalling the runtime.
        let missing = ProcessLaunchError.workingDirectoryUnavailable("feature-123")
        #expect(!missing.userMessage.isEmpty)
        #expect(missing.recoveryActions == [.inspectState, .retry, .cancel])
        #expect(missing.errorDescription == missing.userMessage)
    }
}
