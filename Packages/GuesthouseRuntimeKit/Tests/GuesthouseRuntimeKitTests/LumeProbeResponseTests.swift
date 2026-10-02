import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct LumeProbeResponseTests {
    private final class Fixture: Sendable {
        let base, root, record: URL
        init() throws {
            var template = Array("/private/tmp/guesthouse-probe-response-XXXXXX".utf8CString)
            base = URL(fileURLWithPath: String(cString: try #require(mkdtemp(&template))))
            root = base.appending(path: "Guesthouse")
            record = root.appending(path: "state/lume-ownership.json")
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func fresh() async throws -> StateStore { try await StateStore.createFresh(root: { self.root }) }
        func saved() throws -> LumeRuntimeOwnership {
            try JSONDecoder().decode(LumeRuntimeOwnership.self, from: Data(contentsOf: record))
        }
        // Real benign native fixtures exercise completion, not provider verification/launch.
        // No fabricated report, saved proof or verifier override grants settlement authority.
        func launch(_ owner: StateStore, command: LumeLaunchIntent.Command = .version,
                    text: String = "0.5.3", executable: String = "/usr/bin/printf",
                    arguments: [String]? = nil, observing: Bool = true,
                    limit: Int = 1 << 20, timeout: Duration = .seconds(5)) async throws -> LumeProbeLaunch {
            try await owner.withLumeLaunchIntent(command: command) { intent in
                var invocation = ProcessInvocation(executable: URL(fileURLWithPath: executable), arguments: arguments ?? ["%s", text])
                invocation.observation = observing ? .forkHistory : .ordinary
                invocation.capturing = [.stdout]; invocation.maximumOutputBytes = limit
                invocation.timeout = timeout; invocation.terminationGracePeriod = .zero
                let run = try await ProcessRunner().run(invocation, runID: intent.attemptID)
                try await owner.attachOwnedLumeChild(run.ownedChild, to: intent)
                return LumeProbeLaunch(intent: intent, run: run)
            }
        }
    }

    @Test(arguments: ["0.5.3.0", "00.5.3", "0.6.0", "lume 0.5.3", "0.5.3\nsecret"])
    func versionRequiresTheExactPin(_ text: String) throws {
        #expect(throws: LumeProbeResponseFailure.self) { _ = try LumeProbeResponse.parse(Data(text.utf8), command: .version) }
        #expect(try LumeProbeResponse.parse(Data(" 0.5.3\n".utf8), command: .version) == .version(LumePin.version))
    }

    @Test func helpFlagsAreAdvertisementsWithExactTokens() throws {
        #expect(try LumeProbeResponse.parse(Data("--unattended (TAHOE) --storage=<path>".utf8), command: .createHelp)
            == .createHelp(unattendedTahoeAdvertised: true, storageAdvertised: true))
        #expect(try LumeProbeResponse.parse(Data("--unattended-more tahoex --storage-more".utf8), command: .createHelp)
            == .createHelp(unattendedTahoeAdvertised: false, storageAdvertised: false))
        #expect(try LumeProbeResponse.parse(Data("--detach --storage --vnc disabled --vnc-port".utf8), command: .detachedRunHelp)
            == .detachedRunHelp(detachAdvertised: true, storageAdvertised: true))
        #expect(try LumeProbeResponse.parse(Data("--display NATIVE --storage".utf8), command: .attachHelp)
            == .attachHelp(nativeDisplayAdvertised: true, storageAdvertised: true))
        #expect(try LumeProbeResponse.parse(Data("--display-more supernative native2".utf8), command: .attachHelp)
            == .attachHelp(nativeDisplayAdvertised: false, storageAdvertised: false))
    }

    @Test(arguments: [Data(), Data([0xff]), Data("0.5.3\0".utf8), Data(repeating: 32, count: (1 << 20) + 1)])
    func invalidBytesAreNeverInterpreted(_ bytes: Data) {
        for command in LumeLaunchIntent.Command.allCases {
            #expect(throws: LumeProbeResponseFailure.invalidResponse) { _ = try LumeProbeResponse.parse(bytes, command: command) }
        }
    }

    @Test(arguments: LumeLaunchIntent.Command.allCases)
    func actualCompletionSettlesBeforeSuccessAndExposesNoOutput(_ command: LumeLaunchIntent.Command) async throws {
        let f = try Fixture(), owner = try await f.fresh(), log = Mutex(DiagnosticLog())
        let text = command == .version ? "0.5.3" : "secret=DO-NOT-EXPORT --unattended Tahoe --storage --detach --display native"
        let launch = try await f.launch(owner, command: command, text: text)
        let pending = try Data(contentsOf: f.record)
        let value = try await owner.inspectLumeProbeResponse(launch) { event in log.withLock { $0.append(event) } }
        #expect(value == (try LumeProbeResponse.parse(Data(text.utf8), command: command)))
        #expect(try f.saved().intent == nil && f.saved().child == nil)
        #expect(try Data(contentsOf: f.record) != pending)
        #expect(launch.run.ownedChild.forkObservation == .exitedWithoutFork)
        let events = log.withLock { $0.records.map(\.event) }
        #expect(events.map(\.outcome) == [.started, .succeeded])
        #expect(events.allSatisfy { $0.operationID == launch.intent.operationID && $0.environmentID == nil })
        #expect(try log.withLock { String(decoding: try $0.jsonData(), as: UTF8.self) }.contains("DO-NOT-EXPORT") == false)
        #expect(await launch.run.takeOutput() == nil)
        let next = try await owner.withLumeLaunchIntent(command: .version) { $0 }
        #expect(next.attemptID != launch.intent.attemptID)
        await owner.close()
    }

    @Test(arguments: ["bad-version", "truncated", "nonzero", "timeout", "ordinary"])
    func failuresPreserveIntentAndClosedDiagnosticAttribution(_ kind: String) async throws {
        let f = try Fixture(), owner = try await f.fresh(), log = Mutex(DiagnosticLog())
        let launch = try await f.launch(owner, text: kind == "bad-version" ? "secret=DO-NOT-EXPORT" : "0.5.3",
            executable: kind == "nonzero" ? "/usr/bin/false" : kind == "timeout" ? "/bin/sleep" : "/usr/bin/printf",
            arguments: kind == "nonzero" ? [] : kind == "timeout" ? ["30"] : nil,
            observing: kind != "ordinary", limit: kind == "truncated" ? 2 : 1 << 20,
            timeout: kind == "timeout" ? .milliseconds(50) : .seconds(5))
        let before = try Data(contentsOf: f.record)
        await #expect(throws: (any Error).self) {
            _ = try await owner.inspectLumeProbeResponse(launch) { event in log.withLock { $0.append(event) } }
        }
        #expect(try Data(contentsOf: f.record) == before)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await owner.withLumeLaunchIntent(command: .version) { $0 } }
        let events = log.withLock { $0.records.map(\.event) }
        #expect(events.count == 2 && events.first?.outcome == .started && events.last?.outcome != .succeeded)
        #expect(events.allSatisfy { $0.operationID == launch.intent.operationID && $0.environmentID == nil })
        #expect(!log.withLock { $0.text }.contains("DO-NOT-EXPORT"))
        #expect(events.last?.recoveryMessage != nil)
        await owner.close()
    }

    @Test func cancellationRetainsTheActualOwnerAndNeverReportsConfirmedCancellation() async throws {
        let f = try Fixture(), owner = try await f.fresh(), log = Mutex(DiagnosticLog())
        let launch = try await f.launch(owner, executable: "/bin/sleep", arguments: ["30"])
        let before = try Data(contentsOf: f.record)
        let began = AsyncStream<Void>.makeStream()
        let task = Task {
            return try await owner.inspectLumeProbeResponse(launch) { event in
                log.withLock { $0.append(event) }
                if event.outcome == .started { began.continuation.yield(()) }
            }
        }
        var started = began.stream.makeAsyncIterator()
        _ = await started.next(); task.cancel()
        await #expect(throws: LumeProbeResponseFailure.interrupted) { _ = try await task.value }
        began.continuation.finish()
        #expect(try Data(contentsOf: f.record) == before)
        #expect(log.withLock { $0.records.map(\.event.outcome) } == [.started, .failed(.outcomeUnknown)])
        await owner.close()
    }

    @Test func foreignRunAndRestartCannotBorrowTheSavedReceipt() async throws {
        let f = try Fixture(), owner = try await f.fresh(), log = Mutex(DiagnosticLog())
        let launch = try await f.launch(owner)
        let other = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/true")), runID: launch.intent.attemptID)
        let forged = LumeProbeLaunch(intent: launch.intent, run: other), before = try Data(contentsOf: f.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) {
            _ = try await owner.inspectLumeProbeResponse(forged) { event in log.withLock { $0.append(event) } }
        }
        #expect(log.withLock { $0.records.isEmpty })
        _ = try await other.waitForExit(); _ = try await launch.run.waitForExit()
        await owner.close()
        let restarted = try await StateStore.open(storage: { try RuntimeStorage(existingRoot: f.root) })
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await restarted.inspectLumeProbeResponse(launch) }
        #expect(try Data(contentsOf: f.record) == before)
        await restarted.close()
    }

    @Test func genuineForkCannotBecomeAProbeSuccess() async throws {
        let f = try Fixture(), owner = try await f.fresh()
        let source = f.base.appending(path: "fork.c"), executable = f.base.appending(path: "fork")
        try Data("""
        #include <unistd.h>
        #include <sys/wait.h>
        int main(void) { pid_t pid = fork(); if (pid < 0) return 1;
            if (!pid) _exit(0); int status;
            if (waitpid(pid, &status, 0) != pid) return 2;
            return write(1, "0.5.3", 5) == 5 ? 0 : 3; }
        """.utf8).write(to: source)
        let build = try await ProcessRunner().run(ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: ["-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path]))
        try #require(await build.waitForExit().childExit == .success(.status(0)))
        let launch = try await f.launch(owner, executable: executable.path, arguments: [])
        let before = try Data(contentsOf: f.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await owner.inspectLumeProbeResponse(launch) }
        #expect(launch.run.ownedChild.forkObservation == .forkObserved)
        #expect(try Data(contentsOf: f.record) == before)
        await owner.close()
    }

    @Test func everyResponseErrorHasPreservationFirstRecovery() {
        for error in [LumeProbeResponseFailure.interrupted, .timedOut, .processFailed(status: 1), .invalidResponse, .versionMismatch] {
            #expect(!error.userMessage.isEmpty && error.errorDescription == error.userMessage)
            #expect(error.recoveryActions.contains(.inspectState) && !error.recoveryActions.contains(.repair(.runtime)))
        }
    }

    @Test(arguments: ["write", "directory"])
    func failedPublicationCannotEmitSuccessOrPermitReplacement(_ stage: String) async throws {
        let f = try Fixture(), fresh = try await f.fresh(), failing = Mutex(false), log = Mutex(DiagnosticLog())
        await fresh.close()
        let owner = try await StateStore.open(storage: { try RuntimeStorage(existingRoot: f.root) },
            hooks: StateStoreHooks(ownershipWrite: { fd, bytes in
                if stage == "write", failing.withLock({ $0 }) { throw StateStoreError.fileUnwritable(name: .runtimeOwnership) }
                try StateFileIO.writeAll(fd, bytes, name: .runtimeOwnership)
            }, synchronize: { fd, name in
                if stage == "directory", name == .stateDirectory, failing.withLock({ $0 }) {
                    throw StateStoreError.fileUnwritable(name: name)
                }
                try StateFileIO.fullySynchronize(fd, name: name)
            }))
        let launch = try await f.launch(owner)
        failing.withLock { $0 = true }
        await #expect(throws: StateStoreError.self) {
            _ = try await owner.inspectLumeProbeResponse(launch) { event in log.withLock { $0.append(event) } }
        }
        #expect(log.withLock { $0.records.map(\.event.outcome) } == [.started, .failed(.outcomeUnknown)])
        // A post-rename failure may expose idle on disk, but the live store stays uncertain.
        #expect((try f.saved().intent == nil) == (stage == "directory"))
        failing.withLock { $0 = false }
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await owner.withLumeLaunchIntent(command: .version) { $0 } }
        await owner.close()
    }

    @Test func closingDuringTheActualWaitCannotBorrowPriorAuthority() async throws {
        let f = try Fixture(), owner = try await f.fresh(), began = AsyncStream<Void>.makeStream()
        let launch = try await f.launch(owner, executable: "/bin/sleep", arguments: ["0.2"])
        let before = try Data(contentsOf: f.record)
        let task = Task { try await owner.inspectLumeProbeResponse(launch) { event in
            if event.outcome == .started { began.continuation.yield(()) }
        } }
        var started = began.stream.makeAsyncIterator()
        _ = await started.next(); await owner.close()
        await #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) { _ = try await task.value }
        began.continuation.finish()
        #expect(try Data(contentsOf: f.record) == before)
    }
}
