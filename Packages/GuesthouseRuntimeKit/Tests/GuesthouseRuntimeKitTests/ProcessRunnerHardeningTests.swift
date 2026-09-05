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
        #expect(!ProcessExit(reason: .status(0), terminationRefused: true).succeeded, "a process that refused the signal may still be running")
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
            descendants = Array(ProcessRun.descendants(of: run.processIdentifier).keys)
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

    /// Every helper is captured with the identity it was listed with, and only while it is
    /// still a child of the process it was listed under: a PID the kernel reuses during the
    /// walk would otherwise be recorded as a helper this run forked and signaled as one.
    @Test func descendantsCarryTheIdentityTheyWereFoundWith() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/caffeinate"), arguments: ["-i", "/bin/sleep", "30"], timeout: .seconds(30), terminationGracePeriod: .milliseconds(200)))
        var found: [pid_t: Date] = [:]
        for _ in 0..<100 where found.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            found = ProcessRun.descendants(of: run.processIdentifier)
        }
        #expect(!found.isEmpty, "caffeinate should have spawned sleep")
        for (pid, start) in found {
            let identity = try #require(ProcessRun.identity(of: pid))
            #expect(identity.start == start, "the helper was captured with the identity it was listed with")
            #expect(identity.parent == run.processIdentifier || found[identity.parent] != nil, "every captured helper hangs below the child")
        }
        run.terminate(gracePeriod: .milliseconds(200))
        #expect(await run.exit().terminated)
    }

    /// A helper that inherits the pipes keeps the run shutting down long after the child is
    /// gone. The invocation's deadline still governs that window: it expires while nothing is
    /// running to signal, and the caller is told the run timed out instead of being handed a
    /// success five seconds past the limit it asked for.
    ///
    /// `/bin/sh` is the subject here rather than a way to build a command, and nothing is
    /// interpolated into its arguments.
    @Test func aDeadlineThatExpiresWhileTheRunIsShuttingDownIsReported() async throws {
        let started = ContinuousClock.now
        let run = try await runner.run(ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 3 & exit 0"],
            timeout: .milliseconds(300),
            terminationGracePeriod: .milliseconds(200)
        ))
        let exit = await run.exit()
        let waited = ContinuousClock.now - started
        #expect(exit.timedOut, "the deadline expired before the outcome was reported")
        #expect(!exit.succeeded)
        #expect(waited < .seconds(2), "the run outlived the limit it advertised by the whole drain window")
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
        #expect(records.map { String(decoding: $0.bytes, as: UTF8.self) } == ["one", "two", "three"])

        let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let filler = String(repeating: "x", count: RecordSplitter.maximumRecordBytes - 20)
        var straddling = RecordSplitter()
        var chunks = straddling.consume(Data((filler + " " + token + " tail").utf8))
        chunks += [straddling.flush()].compactMap { $0 }
        let texts = chunks.map { String(decoding: $0.bytes, as: UTF8.self) }
        #expect(texts.contains { $0.contains(token) }, "the token is whole in one record")
        #expect(texts.allSatisfy { $0.utf8.count <= RecordSplitter.maximumRecordBytes })

        var multibyte = RecordSplitter()
        let ascii = String(repeating: "y", count: RecordSplitter.maximumRecordBytes - 1)
        var pieces = multibyte.consume(Data((ascii + "😀 end").utf8))
        pieces += [multibyte.flush()].compactMap { $0 }
        #expect(pieces.map { String(decoding: $0.bytes, as: UTF8.self) }.joined() == ascii + "😀 end", "no scalar was torn")
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
        #expect(records.first?.bytes.count == 60 << 10)
        #expect(records.last?.bytes == Data([UInt8(ascii: " ")]) + token, "the cut goes back to the separator, however far it is, and the separator leads what follows")
    }

    @Test func aHeaderValueTornFromItsLabelIsStillRedacted() {
        var splitter = RecordSplitter()
        // The forced cut lands exactly on the space between the label and its value.
        let filler = String(repeating: "x", count: RecordSplitter.maximumRecordBytes - 16)
        let records = splitter.consume(Data("\(filler) Authorization: opaque-secret\n".utf8))
        #expect(records.count == 2)
        #expect(String(decoding: records[1].bytes, as: UTF8.self) == " opaque-secret")

        let redactor = Redactor()
        var state = Redactor.StreamState()
        let texts = records.map { redactor.redact(processOutputLine: String(decoding: $0.bytes, as: UTF8.self), continuesPreviousRecord: $0.continuesPrevious, state: &state).text }
        #expect(!texts.contains { $0.contains("opaque-secret") }, "the value is a folded continuation of the label it was cut from")
        #expect(texts.last == "[redacted:authorization]")
    }

    @Test func aSignalIsWithheldWhenThePIDIsNoLongerTheCapturedProcess() {
        let me = getpid()
        #expect(ProcessRun.signalIfUnchanged(0, to: me, startedAt: ProcessRun.startTime(of: me)) == .delivered)
        // A start time that is not this process's stands for a PID the kernel handed on after
        // the captured process exited; signaling it would hit whoever holds it now.
        #expect(ProcessRun.signalIfUnchanged(0, to: me, startedAt: Date(timeIntervalSince1970: 1)) == .gone)
        #expect(ProcessRun.signalIfUnchanged(0, to: me, startedAt: nil) == .gone)
    }

    /// The escalation exists to reach what is still running. Once the child has exited and
    /// nothing it captured is alive, it can reach nothing: a run that answered in milliseconds
    /// must not be held — with its process, its output buffer and its input channel — for the
    /// rest of a grace period that `terminate(gracePeriod:)` lets a caller set in hours.
    @Test func aQuietGraphDoesNotHoldTheRunForTheRestOfTheGracePeriod() async throws {
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/caffeinate"), arguments: ["-i", "/bin/sleep", "30"], timeout: .seconds(30), terminationGracePeriod: .seconds(1)))
        for _ in 0..<100 where ProcessRun.descendants(of: run.processIdentifier).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        run.terminate(gracePeriod: .seconds(3600))
        #expect(await run.exit().terminated)
        #expect(run.escalationDeadline == nil, "nothing captured is still running, so the escalation had nothing left to reach")
    }

    /// The invocation's deadline stays armed while a captured helper is given a caller's grace
    /// period, so a run can still time out after its child has exited. What the caller is told
    /// has to be what stood when the outcome was committed, not what stood when the child ended.
    ///
    /// The helper has to ignore SIGTERM for that window to exist at all, so this stages it the
    /// way `theExitWaitsForAHelperThatOutlivesTheChild` does: `/bin/sh` is the subject here
    /// rather than a way to build a command, and nothing is interpolated into its arguments.
    @Test func theInterruptionFlagsAreReadWhenTheExitIsReported() async throws {
        let script = "exec >/dev/null 2>&1; /bin/sh -c \"trap '' TERM; sleep 30; sleep 5\" & sleep 30"
        let run = try await runner.run(ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: .seconds(30),
            terminationGracePeriod: .seconds(1)
        ))
        var descendants: [pid_t] = []
        for _ in 0..<300 where descendants.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
            descendants = Array(ProcessRun.descendants(of: run.processIdentifier).keys)
        }
        #expect(descendants.count >= 3, "the helper had not started its own work yet")
        run.terminate(gracePeriod: .seconds(2))
        // The child dies on the signal; the helper refuses it, so the outcome is still pending.
        for _ in 0..<300 where kill(run.processIdentifier, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(run.processIdentifier, 0) != 0, "the child was still running")
        try await Task.sleep(for: .milliseconds(100))
        // The invocation's own deadline expires inside that window. It outranks the grace
        // period the caller asked for, and this run is one that timed out, not only one
        // somebody asked to stop.
        _ = run.stop(gracePeriod: .milliseconds(200), becauseOfTimeout: true)
        let exit = await run.exit()
        #expect(exit.terminated, "the caller did ask for this run to stop")
        #expect(exit.timedOut, "the invocation's deadline expired before the outcome was reported, and the caller has to be told so")
        for pid in descendants {
            for _ in 0..<50 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(kill(pid, 0) != 0, "helper \(pid) outlived the run")
        }
    }

    @Test func theInvocationDeadlineShortensAnOpenEndedTermination() async throws {
        let run = try await runner.run(ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf 'ready\\n'; exec /bin/sleep 60"],
            timeout: .seconds(30),
            terminationGracePeriod: .milliseconds(200)
        ))
        // Readiness proves TERM is ignored, so the first request leaves an escalation pending.
        var output = run.output.makeAsyncIterator()
        let ready = await output.next()
        try #require(ready?.line.text == "ready")
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
        #expect(first.first?.bytes.count == RecordSplitter.maximumRecordBytes - 1)
        var rest = Data([0x82, 0xAC])
        rest.append(UInt8(ascii: "\n"))
        #expect(splitter.consume(rest).map(\.bytes) == [Data([0xE2, 0x82, 0xAC])])
    }

    @Test func outputAfterTheConsumerStopsListeningIsReportedTruncated() async throws {
        let run = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: .seconds(20)))
        await Task { for await _ in run.output { break } }.value
        try await Task.sleep(for: .milliseconds(100))
        run.terminate(gracePeriod: .milliseconds(200))
        let exit = await run.exit()
        #expect(exit.outputTruncated, "lines the stream no longer accepted are missing from what the awaiting owner saw")
    }

    /// The cut can land on any separator, and only whitespace reads as a folded continuation,
    /// so the tail has to carry the context of the record it was cut from instead.
    @Test func aValueCutFromItsLabelAtPunctuationIsStillRedacted() {
        var splitter = RecordSplitter()
        // The forced cut lands exactly on the comma that opens the value.
        let filler = String(repeating: "x", count: RecordSplitter.maximumRecordBytes - 16)
        let records = splitter.consume(Data("\(filler) Authorization:,opaque-secret\n".utf8))
        #expect(records.count == 2)
        #expect(String(decoding: records[1].bytes, as: UTF8.self) == ",opaque-secret")
        #expect(records[1].continuesPrevious, "the tail of a cut line is not a line of its own")

        let redactor = Redactor()
        var state = Redactor.StreamState()
        let texts = records.map {
            redactor.redact(processOutputLine: String(decoding: $0.bytes, as: UTF8.self), continuesPreviousRecord: $0.continuesPrevious, state: &state).text
        }
        #expect(!texts.contains { $0.contains("opaque-secret") }, "the value belongs to the label it was cut from, whatever byte the cut fell on")
        #expect(texts.last == "[redacted:authorization]")
    }

    /// A passphrase is words and a token is opaque, so no rule recognizes the rest of one on
    /// shape alone: the label that introduced the value has to keep removing it through every
    /// forced cut rather than only the record it was read on (MVP-PLAN.md §3).
    @Test func aSecretValueIsRemovedThroughEveryForcedCut() {
        var splitter = RecordSplitter()
        let records = splitter.consume(Data("password: \(String(repeating: "hunter2 ", count: 20_000))\n".utf8))
        #expect(records.count >= 3, "the value has to outrun more than one record for this to test anything")
        #expect(records.dropFirst().allSatisfy { $0.continuesPrevious })

        let redactor = Redactor()
        var state = Redactor.StreamState()
        let texts = records.map {
            redactor.redact(processOutputLine: String(decoding: $0.bytes, as: UTF8.self), continuesPreviousRecord: $0.continuesPrevious, state: &state).text
        }
        #expect(!texts.contains { $0.contains("hunter2") }, "the rest of the password left the redaction layer verbatim")
        #expect(texts.dropFirst().allSatisfy { $0 == "[redacted:secret]" })
    }

    /// A bearer token is opaque and the reader cuts an over-long line at its last separator,
    /// which for `Bearer <token>` is the space between the two: the word alone arms nothing, so
    /// without a carried context every chunk of the value would leave the redaction layer
    /// verbatim (MVP-PLAN.md §3).
    @Test func aBearerValueIsRemovedThroughEveryForcedCut() {
        var splitter = RecordSplitter()
        let token = String(repeating: "A", count: RecordSplitter.maximumRecordBytes * 2)
        let records = splitter.consume(Data("Bearer \(token)\n".utf8))
        #expect(records.count >= 3, "the value has to outrun more than one record for this to test anything")
        #expect(String(decoding: records[0].bytes, as: UTF8.self) == "Bearer", "the cut goes back to the separator, leaving the label alone")
        #expect(records.dropFirst().allSatisfy { $0.continuesPrevious })

        let redactor = Redactor()
        var state = Redactor.StreamState()
        let texts = records.map {
            redactor.redact(processOutputLine: String(decoding: $0.bytes, as: UTF8.self), continuesPreviousRecord: $0.continuesPrevious, state: &state).text
        }
        #expect(!texts.contains { $0.contains("AAAA") }, "the rest of the bearer token left the redaction layer verbatim")
        #expect(texts.dropFirst().allSatisfy { $0 == "[redacted:secret]" })
    }

    /// A long URL has no separator in it at all — `/`, `:`, `?`, and `=` are none — so the cut
    /// falls wherever the limit did, and that can be inside a token: the first half is too
    /// short for the rule that names it, the second has lost the prefix that does, and both
    /// would leave the redaction layer verbatim. The run of token characters the limit landed
    /// in leads the next record instead of being split.
    @Test func aTokenAcrossAHardCutLeadsTheNextRecord() {
        var splitter = RecordSplitter()
        let token = "ghp_" + String(repeating: "Z", count: 36)
        // Ten bytes of the token sit in front of the limit, so an unguarded cut splits it.
        let prefix = "https://example.com/" + String(repeating: "a", count: RecordSplitter.maximumRecordBytes - 31) + "/"
        let records = splitter.consume(Data("\(prefix)\(token)\n".utf8))
        #expect(records.count == 2)
        #expect(String(decoding: records[0].bytes, as: UTF8.self).hasSuffix("/"), "the cut went back to the start of the token")
        #expect(String(decoding: records[1].bytes, as: UTF8.self) == token)

        let redactor = Redactor()
        var state = Redactor.StreamState()
        let texts = records.map {
            redactor.redact(processOutputLine: String(decoding: $0.bytes, as: UTF8.self), continuesPreviousRecord: $0.continuesPrevious, state: &state).text
        }
        #expect(!texts.contains { $0.contains("ghp_") || $0.contains("ZZZ") }, "a token cut in two matches no rule and leaves as it came")
        #expect(texts.last == "[redacted:github-token]")
    }

    @Test func aRealLineEndingStartsARecordOfItsOwn() {
        var splitter = RecordSplitter()
        let records = splitter.consume(Data("Authorization: x\n,not-a-continuation\n".utf8))
        #expect(records.count == 2)
        #expect(records.allSatisfy { !$0.continuesPrevious })
        let redactor = Redactor()
        var state = Redactor.StreamState()
        let texts = records.map {
            redactor.redact(processOutputLine: String(decoding: $0.bytes, as: UTF8.self), continuesPreviousRecord: $0.continuesPrevious, state: &state).text
        }
        #expect(texts.last == ",not-a-continuation", "a line of its own keeps the shape rule")
    }

    @Test func aRecordThatDoesNotFitTheRemainingCapIsRefusedWhole() async throws {
        // One record can be 64 KiB, so a cap of a few bytes must not admit one whole.
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["0123456789"], maximumOutputBytes: 4))
        let result = await collect(run)
        #expect(result.lines.isEmpty, "a record beyond the remaining budget is not delivered")
        #expect(result.exit.outputTruncated)
        #expect(result.exit.reason == .status(0))
    }

    @Test func aWorkingDirectoryThatIsALinkIsRefused() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "cwd-\(UUID().uuidString)")
        let real = base.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appending(path: "workspace")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        await #expect(throws: ProcessLaunchError.workingDirectoryUnavailable("workspace")) {
            _ = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/pwd"), currentDirectory: link))
        }
        // The directory itself is still a working directory; only the link to it is refused.
        let run = try await runner.run(ProcessInvocation(executable: URL(fileURLWithPath: "/bin/pwd"), currentDirectory: real))
        #expect(await run.exit().succeeded)
    }

    /// A helper that outlives the child is still changing the host, so the run is not over
    /// until it is gone or the escalation that kills it has run (MVP-PLAN.md §4).
    ///
    /// The helper has to ignore SIGTERM for the situation to exist at all: the kernel runs even
    /// a stopped process to deliver a terminating signal, so no ordinary program survives the
    /// one termination sends. `/bin/sh` is the subject under test here rather than a way to
    /// build a command — the argument array is fixed and nothing is interpolated into it.
    @Test func theExitWaitsForAHelperThatOutlivesTheChild() async throws {
        // The child gives up the inherited pipes before it starts the helper, so the run's own
        // drain wait finishes at once and what this measures is the wait for the helper. The
        // child then dies on the termination signal while the helper it left behind does not.
        let script = "exec >/dev/null 2>&1; /bin/sh -c \"trap '' TERM; sleep 30; sleep 5\" & sleep 30"
        let run = try await runner.run(ProcessInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: .seconds(30),
            terminationGracePeriod: .seconds(1)
        ))
        // Three: the child's own sleep, the helper shell, and the sleep the helper reaches only
        // after it has refused the termination signal. Waiting for the third is what makes this
        // a helper that outlives the child rather than one caught before it was ready.
        var descendants: [pid_t] = []
        for _ in 0..<300 where descendants.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
            descendants = Array(ProcessRun.descendants(of: run.processIdentifier).keys)
        }
        #expect(descendants.count >= 3, "the helper had not started its own work yet")
        let started = ContinuousClock.now
        run.terminate(gracePeriod: .seconds(1))
        let exit = await run.exit()
        let waited = ContinuousClock.now - started
        #expect(exit.terminated)
        #expect(waited > .milliseconds(500), "the exit was reported while a helper the run owns was still running")
        for pid in descendants {
            for _ in 0..<50 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(kill(pid, 0) != 0, "helper \(pid) outlived the run")
        }
    }

    /// An escalation an earlier deadline took over has nothing left to do; left to sleep out
    /// its original grace period it would hold the run, its process and its buffers for hours.
    @Test func anEscalationSupersededByAnEarlierDeadlineIsReleased() async throws {
        weak var released: ProcessRun?
        do {
            let run = try await runner.run(ProcessInvocation(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; printf 'ready\\n'; exec /bin/sleep 60"],
                timeout: .seconds(30),
                terminationGracePeriod: .milliseconds(200)
            ))
            released = run
            // A stopped child can still die on SIGTERM. Wait until this fixture has ignored
            // TERM (preserved across exec) so the second request meets an active escalation.
            var output = run.output.makeAsyncIterator()
            let ready = await output.next()
            try #require(ready?.line.text == "ready")
            _ = run.stop(gracePeriod: .seconds(3600), becauseOfTimeout: false)
            _ = run.stop(gracePeriod: .milliseconds(200), becauseOfTimeout: true)
            #expect(await run.exit().timedOut)
        }
        for _ in 0..<250 where released != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(released == nil, "the superseded escalation held the run for its whole original grace period")
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
