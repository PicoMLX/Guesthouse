import Foundation
import GuesthouseCore

/// Runtime-only invocation retained from #69. The service selects trusted executables/options;
/// this is not a GUI request, root-containment check, or provider verification (MVP-PLAN.md §3).
struct ProcessInvocation: Sendable {
    enum StandardInput: Sendable { case none, data(Data) }
    let executable: URL
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var currentDirectory: URL?
    var standardInput: StandardInput = .none
    var timeout: Duration = .seconds(60)
    var terminationGracePeriod: Duration = .seconds(5)
    var maximumOutputBytes = 0
    var capturing: Set<OutputReaders.Kind> = []
}

enum ProcessLaunchFailure: Error, Equatable, Sendable {
    case invalidOptions, canceled, workingDirectoryUnavailable, pipeUnavailable, executableUnavailable
    var message: String {
        switch self {
        case .invalidOptions: "The requested tool operation exceeds Guesthouse's supported limits."
        case .canceled: "The tool operation was canceled before it started."
        case .workingDirectoryUnavailable: "The operation's working folder is missing or cannot be opened safely."
        case .pipeUnavailable: "Guesthouse could not prepare the tool's input and output."
        case .executableUnavailable: DiagnosticFailure.executableUnavailable.message
        }
    }
    var recoveryActions: [RecoveryAction] {
        switch self {
        case .invalidOptions: [.reviewRequest, .cancel]
        case .canceled, .workingDirectoryUnavailable: [.inspectState, .cancel]
        case .pipeUnavailable: [.inspectState, .reinstallApp, .cancel]
        case .executableUnavailable: [.repair(.runtime), .cancel]
        }
    }
}

struct ProcessRunner: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        guard !Task.isCancelled else { throw ProcessLaunchFailure.canceled }
        guard invocation.timeout >= .zero, invocation.timeout <= .seconds(86_400),
              invocation.terminationGracePeriod >= .zero, invocation.terminationGracePeriod <= .seconds(60)
        else { throw ProcessLaunchFailure.invalidOptions }
        let data: Data?
        switch invocation.standardInput {
        case .none: data = nil
        case .data(let bytes):
            guard bytes.count <= 4 << 20 else { throw ProcessLaunchFailure.invalidOptions }
            data = bytes
        }
        let directory: PinnedWorkingDirectory?
        do { directory = try invocation.currentDirectory.map(PinnedWorkingDirectory.init) }
        catch { throw ProcessLaunchFailure.workingDirectoryUnavailable }
        let stdout = Pipe(), stderr = Pipe(), stdin = data == nil ? nil : Pipe()
        let readers = OutputReaders(maximumBytes: invocation.maximumOutputBytes, capturing: invocation.capturing)
        var outReader: FileHandle? = stdout.fileHandleForReading
        var errReader: FileHandle? = stderr.fileHandleForReading
        var inputWriter = stdin?.fileHandleForWriting
        var delivery: InputDelivery?
        var nullInput: FileHandle?
        defer {
            try? outReader?.close(); try? errReader?.close(); try? inputWriter?.close()
            try? nullInput?.close()
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            try? stdin?.fileHandleForReading.close()
        }
        do {
            // Foundation.Process understands FileHandle.nullDevice's sentinel. posix_spawn
            // needs a real borrowed descriptor, owned here only until launch returns.
            if data == nil { nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null")) }
            try readers.attach(stdout.fileHandleForReading, kind: .stdout); outReader = nil
            try readers.attach(stderr.fileHandleForReading, kind: .stderr); errReader = nil
            if let writer = inputWriter { delivery = try InputDelivery(writer); inputWriter = nil }
        } catch {
            readers.detach(); delivery?.cancel()
            throw ProcessLaunchFailure.pipeUnavailable
        }
        let child: OwnedChild
        let deadline = ContinuousClock.now + invocation.timeout
        do {
            guard !Task.isCancelled else { throw ProcessLaunchFailure.canceled }
            child = try OwnedChild.spawn(executable: invocation.executable, arguments: invocation.arguments,
                environment: invocation.environment, workingDirectory: directory,
                standardInput: stdin?.fileHandleForReading.fileDescriptor ?? nullInput?.fileDescriptor ?? -1,
                standardOutput: stdout.fileHandleForWriting.fileDescriptor, standardError: stderr.fileHandleForWriting.fileDescriptor)
        } catch {
            readers.detach(); delivery?.cancel()
            throw (error as? ProcessLaunchFailure) ?? .executableUnavailable
        }
        let run = ProcessRun(child: child, readers: readers, input: delivery, grace: invocation.terminationGracePeriod)
        await run.start(deadline: deadline, input: data)
        if Task.isCancelled { await run.terminate(gracePeriod: invocation.terminationGracePeriod) }
        return run
    }
}
