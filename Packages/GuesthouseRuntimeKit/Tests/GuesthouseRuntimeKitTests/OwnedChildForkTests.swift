import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct OwnedChildForkTests {
    private final class Fixture: Sendable {
        let base, executable: URL
        init() async throws {
            var template = Array("/private/tmp/guesthouse-fork-observation-XXXXXX".utf8CString)
            let name = try #require(mkdtemp(&template))
            base = URL(fileURLWithPath: String(cString: name))
            executable = base.appending(path: "fixture")
            let source = base.appending(path: "fixture.c")
            try Data(Self.source.utf8).write(to: source)
            var invocation = ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/clang"))
            invocation.arguments = ["-Wall", "-Wextra", "-Werror", source.path, "-o", executable.path]
            invocation.timeout = .seconds(20)
            invocation.capturing = [.stderr]; invocation.maximumOutputBytes = 4096
            let run = try await ProcessRunner().run(invocation)
            let report = try await run.waitForExit()
            let response = await run.takeOutput()
            try #require(report.childExit == .success(.status(0)),
                Comment(rawValue: String(decoding: response?.stderr ?? Data(), as: UTF8.self)))
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func spawn(_ mode: String, observing: Bool = true, calls: OwnedChild.SystemCalls = .live,
                   input: Int32? = nil, output: Int32? = nil) throws -> OwnedChild {
            let fd = open("/dev/null", O_RDWR | O_CLOEXEC)
            try #require(fd >= 0)
            defer { close(fd) }
            return try OwnedChild.spawn(observingForks: observing, executable: executable, arguments: [mode],
                standardInput: input ?? fd, standardOutput: output ?? fd, standardError: fd, calls: calls)
        }
        // Benign native process-creation fixtures only; never a shell or provider artifact.
        private static let source = """
        #include <unistd.h>
        #include <stdlib.h>
        #include <stdio.h>
        #include <string.h>
        #include <spawn.h>
        #include <sys/wait.h>
        int main(int argc, char **argv) {
            if (argc != 2) return 1;
            if (!strcmp(argv[1], "none")) return 0;
            pid_t pid;
            if (!strcmp(argv[1], "spawn")) {
                char *args[] = {"/usr/bin/true", NULL}, *env[] = {NULL};
                if (posix_spawn(&pid, args[0], NULL, NULL, args, env)) return 2;
            } else if (!strcmp(argv[1], "escape")) {
                int ready[2]; if (pipe(ready)) return 3;
                pid = fork(); if (pid < 0) return 4;
                if (!pid) {
                    close(ready[0]); if (setsid() < 0) _exit(5);
                    pid_t self = getpid();
                    if (write(1, &self, sizeof(self)) != sizeof(self)) _exit(6);
                    if (write(ready[1], "r", 1) != 1) _exit(7);
                    close(ready[1]); char value;
                    if (read(0, &value, 1) != 1) _exit(8);
                    _exit(0);
                }
                close(ready[1]); char value;
                int count = (int)read(ready[0], &value, 1); close(ready[0]);
                return count == 1 ? 0 : 9;
            } else {
                // Cover the deprecated API deliberately; production never calls it.
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                pid = !strcmp(argv[1], "vfork") ? vfork() : fork();
                #pragma clang diagnostic pop
                if (pid < 0) return 10;
                if (!pid) _exit(0);
            }
            int status;
            return waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 11;
        }
        """
    }

    @Test func observationStartsBeforeFastUserCodeAndEndsBeforeReaping() async throws {
        let fixture = try await Fixture()
        for _ in 0..<20 {
            let child = try fixture.spawn("none")
            let exit = await child.waitForReapedExit()
            #expect(exit == .success(.status(0)))
            #expect(child.forkObservation == .exitedWithoutFork)
            #expect(child.signal(SIGTERM) == .alreadyReaped)
        }
    }

    @Test(arguments: ["fork", "spawn", "vfork"])
    func everyObservedCreationStaysUnprovenEvenIfAllChildrenExit(_ mode: String) async throws {
        let fixture = try await Fixture(), child = try fixture.spawn(mode)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(child.forkObservation == .forkObserved)
    }

    @Test func escapedDescendantIsNotHiddenByLeaderExitOrEmptyOriginalGroup() async throws {
        let fixture = try await Fixture(), input = Pipe(), output = Pipe()
        let child = try fixture.spawn("escape", input: input.fileHandleForReading.fileDescriptor,
                                      output: output.fileHandleForWriting.fileDescriptor)
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        defer { try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        // Closing input also releases the fixture if an assertion throws. Never signal
        // a PID supplied by fixture output or change the test host's SIGPIPE disposition.
        let bytes = try #require(try output.fileHandleForReading.read(upToCount: MemoryLayout<pid_t>.size))
        try #require(bytes.count == MemoryLayout<pid_t>.size)
        let pid = bytes.withUnsafeBytes { $0.loadUnaligned(as: pid_t.self) }
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(getpgid(pid) == pid) // This live descendant escaped the original session/group.
        #expect(child.forkObservation == .forkObserved)
        #expect(getpgid(child.processIdentifier) == -1)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        #expect(try output.fileHandleForReading.readToEnd()?.isEmpty != false)
    }

    @Test func ordinaryLaunchCannotMintForkHistoryAfterTheFact() async throws {
        let fixture = try await Fixture(), child = try fixture.spawn("none", observing: false)
        #expect(await child.waitForReapedExit() == .success(.status(0)))
        #expect(child.forkObservation == .unproven)
    }

    @Test(arguments: ["none", "fork", "spawn", "vfork"])
    func runnerRetainsActualHistoryWithoutChangingItsReport(_ mode: String) async throws {
        let fixture = try await Fixture(), runID = UUID()
        var invocation = ProcessInvocation(executable: fixture.executable, arguments: [mode])
        invocation.observation = .forkHistory
        let run = try await ProcessRunner().run(invocation, runID: runID)
        let report = try await run.waitForExit()
        #expect(report.childExit == .success(.status(0)))
        #expect(report.descendantScopeUnproven && report.outputComplete)
        #expect(run.ownedChild.launchIdentity?.runID == runID)
        #expect(run.ownedChild.forkObservation == (mode == "none" ? .exitedWithoutFork : .forkObserved))
        #expect(run.ownedChild.signal(SIGTERM) == .alreadyReaped)
    }

    @Test func runnerDoesNotObserveOrdinaryLaunchesRetroactively() async throws {
        let fixture = try await Fixture()
        let run = try await ProcessRunner().run(ProcessInvocation(executable: fixture.executable, arguments: ["none"]))
        let report = try await run.waitForExit()
        #expect(report.childExit == .success(.status(0)))
        #expect(report.descendantScopeUnproven && run.ownedChild.forkObservation == .unproven)
    }

    @Test func unavailableBirthPreventsResumingUnobservedCode() async throws {
        let fixture = try await Fixture()
        var calls = OwnedChild.SystemCalls.live
        calls.birth = { _ in .unavailable }
        let child = try fixture.spawn("escape", calls: calls)
        #expect(await child.waitForReapedExit() == .success(.signal(SIGKILL)))
        #expect(child.launchIdentity == nil)
        #expect(child.forkObservation == .unproven)
    }

    @Test func refusedResumeAbortsOnlyTheActualSuspendedChild() async throws {
        let fixture = try await Fixture()
        var calls = OwnedChild.SystemCalls.live
        calls.signal = { pid, value in
            value == SIGCONT ? .refused(EPERM) : OwnedChild.SystemCalls.live.signal(pid, value)
        }
        let child = try fixture.spawn("escape", calls: calls)
        let exit = await child.waitForReapedExit()
        #expect(exit == .success(.signal(SIGKILL)))
        #expect(child.signal(SIGTERM) == .alreadyReaped)
    }

    @Test func waitAuthorityLossNeverPublishesAQuietConclusion() async throws {
        let fixture = try await Fixture()
        var calls = OwnedChild.SystemCalls.live
        calls.reap = { pid in
            // Actually reap the benign child while simulating the facade's lost authority.
            _ = OwnedChild.SystemCalls.live.reap(pid)
            return .failure(.waitAuthorityLost(ECHILD))
        }
        let child = try fixture.spawn("none", calls: calls)
        #expect(await child.waitForReapedExit() == .failure(.waitAuthorityLost(ECHILD)))
        #expect(child.forkObservation == .unproven)
    }
}
