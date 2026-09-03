import Foundation
import GuesthouseCore
@testable import GuesthouseRuntimeKit

/// A `ProcessRunning` that never launches anything: it records invocations and answers each
/// from a script keyed by the first argument, or from fixed output.
actor FakeProcessRunner: ProcessRunning {
    struct Reply: Sendable {
        var stdout: [String] = []
        var stderr: [String] = []
        var exit: ProcessExit = ProcessExit(reason: .status(0))
        /// The run stays alive until `finishHanging` or termination.
        var hangs = false
    }

    private(set) var invocations: [ProcessInvocation] = []
    private var fixed: Reply
    private var script: [String: Reply] = [:]
    private var hanging: [ProcessRun] = []

    init(stdout: [String] = [], stderr: [String] = [], exit: ProcessExit) {
        fixed = Reply(stdout: stdout, stderr: stderr, exit: exit)
    }

    init(script: [String: Reply]) {
        fixed = Reply()
        self.script = script
    }

    func set(_ command: String, _ reply: Reply) { script[command] = reply }

    /// Ends every hanging run. Hanging runs are real `sleep` processes (so they have a pid and
    /// a start time the supervisor can record); ending them terminates the process, and the
    /// run reports a `terminated` exit with SIGTERM.
    func finishHanging(with exit: ProcessExit = ProcessExit(reason: .status(0))) async {
        for run in hanging {
            run.terminate(gracePeriod: .milliseconds(200))
            _ = await run.exit()
        }
        hanging.removeAll()
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        invocations.append(invocation)
        let reply = invocation.arguments.first.flatMap { script[$0] } ?? fixed
        if reply.hangs {
            // A real process, so the supervisor can record a pid and a start time. When the
            // invocation's executable exists (a fixture bundle whose binary is a copy of
            // `yes`), it runs with the invocation's own arguments so identity checks hold.
            let executable = FileManager.default.isExecutableFile(atPath: invocation.executable.path) ? invocation.executable : URL(fileURLWithPath: "/bin/sleep")
            let arguments = executable == invocation.executable ? invocation.arguments : ["600"]
            let run = try await ProcessRunner().run(ProcessInvocation(executable: executable, arguments: arguments, timeout: min(invocation.timeout, .seconds(600)), terminationGracePeriod: .milliseconds(500), maximumOutputBytes: 64 << 10))
            hanging.append(run)
            return run
        }
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessOutput.self, bufferingPolicy: .unbounded)
        let run = ProcessRun(process: Process(), output: stream, continuation: continuation)
        let redactor = Redactor()
        for line in reply.stdout { continuation.yield(.stdout(redactor.redact(lines: [line])[0])) }
        for line in reply.stderr { continuation.yield(.stderr(redactor.redact(lines: [line])[0])) }
        run.finish(with: reply.exit.reason)
        return run
    }
}
