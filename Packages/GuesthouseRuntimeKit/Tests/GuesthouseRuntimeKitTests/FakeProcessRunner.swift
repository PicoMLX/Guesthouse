import Foundation
import GuesthouseCore
@testable import GuesthouseRuntimeKit

/// A `ProcessRunning` that never launches anything: it records invocations and replays
/// scripted output and an exit.
actor FakeProcessRunner: ProcessRunning {
    private(set) var invocations: [ProcessInvocation] = []
    private let stdout: [String]
    private let stderr: [String]
    private let exit: ProcessExit

    init(stdout: [String] = [], stderr: [String] = [], exit: ProcessExit) {
        self.stdout = stdout
        self.stderr = stderr
        self.exit = exit
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        invocations.append(invocation)
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessOutput.self, bufferingPolicy: .unbounded)
        let run = ProcessRun(process: Process(), output: stream, continuation: continuation)
        let redactor = Redactor()
        for line in stdout { continuation.yield(.stdout(redactor.redact(lines: [line])[0])) }
        for line in stderr { continuation.yield(.stderr(redactor.redact(lines: [line])[0])) }
        run.finish(with: exit.reason)
        return run
    }
}
