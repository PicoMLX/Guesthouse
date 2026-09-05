import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

private actor ScriptedLumeRunner: ProcessRunning {
    struct Reply: Sendable {
        var stdout: [String]
        var stderr: [String] = []
        var status: Int32 = 0
        var outputTruncated = false
    }

    private var replies: [String: Reply]
    private let delay: Duration
    private var activeInvocationCount = 0
    private(set) var maximumConcurrentInvocationCount = 0
    private(set) var invocations: [ProcessInvocation] = []

    init(_ replies: [String: Reply], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        invocations.append(invocation)
        activeInvocationCount += 1
        maximumConcurrentInvocationCount = max(maximumConcurrentInvocationCount, activeInvocationCount)
        defer { activeInvocationCount -= 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let reply = replies[invocation.arguments.joined(separator: " ")] else {
            throw LumeInvocationError.unparseableOutput
        }
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessOutput.self, bufferingPolicy: .unbounded)
        let run = ProcessRun(process: Process(), output: stream, continuation: continuation)
        let redactor = Redactor()
        for line in reply.stdout { continuation.yield(.stdout(redactor.redact(lines: [line])[0])) }
        for line in reply.stderr { continuation.yield(.stderr(redactor.redact(lines: [line])[0])) }
        if reply.outputTruncated { run.markOutputTruncated() }
        run.finish(with: .status(reply.status))
        return run
    }
}

/// Produces a real timed-out `ProcessRun` so the Lume adapter's timeout mapping is covered,
/// while still never invoking Lume or accepting caller-controlled commands.
private actor TimedOutLumeRunner: ProcessRunning {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (stream, continuation) = AsyncStream.makeStream(of: ProcessOutput.self, bufferingPolicy: .unbounded)
        let run = ProcessRun(process: process, output: stream, continuation: continuation)
        process.terminationHandler = { process in
            run.finish(with: process.terminationReason == .uncaughtSignal ? .signal(process.terminationStatus) : .status(process.terminationStatus))
        }
        run.retainWhileRunning()
        try process.run()
        run.recordChildIdentity()
        run.timeOut(gracePeriod: .milliseconds(10))
        return run
    }
}

private actor LaunchFailingLumeRunner: ProcessRunning {
    private(set) var invocations: [ProcessInvocation] = []

    func run(_ invocation: ProcessInvocation) async throws -> ProcessRun {
        invocations.append(invocation)
        throw LumeInvocationError.unparseableOutput
    }
}

@Suite(.serialized) struct LumeBackendTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "LumeBackendTests-\(UUID().uuidString)")

    private func verifiedFixture(at url: URL) throws -> VerifiedLumeBundle {
        let bundle = LumeBundle(url: url)
        try FileManager.default.createDirectory(
            at: bundle.executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture metadata".utf8).write(to: url.appending(path: "Contents/Info.plist"))
        try Data("fixture executable".utf8).write(to: bundle.executable)
        return try VerifiedLumeBundle(
            bundle: bundle,
            version: LumePin.version,
            teamIdentifier: LumePin.teamIdentifier,
            signingIdentifier: LumePin.bundleIdentifier
        )
    }

    private func backend(
        runner: any ProcessRunning,
        suffix: String = UUID().uuidString,
        resolvedExecutable: URL? = nil,
        verifyBeforeLaunch: @escaping @Sendable () throws -> Void = {}
    ) throws -> (LumeBackend, RuntimeStorage, VerifiedLumeBundle) {
        let storage = try RuntimeStorage(root: root.appending(path: suffix))
        let verified = try verifiedFixture(at: storage.url(for: .runtime).appending(path: "fixture/lume.app"))
        return (
            LumeBackend(
                bundle: verified,
                storage: storage,
                runner: runner,
                verifyBeforeLaunch: {
                    try verifyBeforeLaunch()
                    return resolvedExecutable ?? verified.executable
                }
            ),
            storage,
            verified
        )
    }

    private static var successfulReplies: [String: ScriptedLumeRunner.Reply] {
        [
            "--version": .init(stdout: ["0.5.3"]),
            "create --help": .init(stdout: ["--unattended tahoe --storage"]),
            "run --detach --help": .init(stdout: ["--detach --storage --vnc-port"]),
            "attach --help": .init(stdout: ["--display native --storage"]),
        ]
    }

    @Test func probeUsesOnlyPinnedIntrospectionAndPrivateState() async throws {
        let runner = ScriptedLumeRunner(Self.successfulReplies)
        let verificationCount = Mutex(0)
        let (backend, storage, bundle) = try backend(runner: runner) {
            verificationCount.withLock { $0 += 1 }
        }

        let result = try await backend.probe()

        #expect(result.version == LumePin.version)
        #expect(result.capabilities == .init(
            unattendedTahoe: true,
            createRunAttachStorage: true,
            detachedRun: true,
            nativeAttach: true,
            vncCanBeDisabled: false
        ))
        let invocations = await runner.invocations
        #expect(invocations.map(\.executable) == Array(repeating: bundle.executable, count: 4))
        #expect(invocations.first?.arguments == ["--version"])
        #expect(invocations.dropFirst().map(\.arguments) == [
            ["create", "--help"],
            ["run", "--detach", "--help"],
            ["attach", "--help"],
        ])
        let expectedEnvironment = try storage.environmentForLume()
        #expect(invocations.allSatisfy { $0.environment == expectedEnvironment })
        #expect(invocations.allSatisfy { $0.currentDirectory == storage.url(for: .staging) && $0.standardInput == .none })
        #expect(invocations.allSatisfy { $0.maximumOutputBytes == 1 << 20 })
        #expect(invocations.allSatisfy { $0.timeout == .seconds(5) })
        #expect(invocations.allSatisfy { !$0.environment.keys.contains("HOME") && !$0.environment.keys.contains("PATH") })
        #expect(verificationCount.withLock { $0 } == 4, "every launch gets a fresh static verification")
    }

    @Test func probesShareOneExclusiveRuntimeLease() async throws {
        let runner = ScriptedLumeRunner(Self.successfulReplies, delay: .milliseconds(10))
        let suffix = UUID().uuidString
        let (first, _, _) = try backend(runner: runner, suffix: suffix)
        let (second, _, _) = try backend(runner: runner, suffix: suffix)

        async let firstResult = first.probe()
        async let secondResult = second.probe()
        _ = try await (firstResult, secondResult)

        let argumentGroups = await runner.invocations.map(\.arguments)
        let expectedGroup = [
            ["--version"],
            ["create", "--help"],
            ["run", "--detach", "--help"],
            ["attach", "--help"],
        ]
        #expect(argumentGroups == expectedGroup + expectedGroup)
        #expect(await runner.maximumConcurrentInvocationCount == 1)
    }

    @Test func probeLaunchesOnlyTheFreshlyResolvedExecutable() async throws {
        let runner = ScriptedLumeRunner(Self.successfulReplies)
        let resolved = root.appending(path: "freshly-relocated-lume")
        let (backend, _, _) = try backend(runner: runner, resolvedExecutable: resolved)

        _ = try await backend.probe()

        #expect(await runner.invocations.allSatisfy { $0.executable == resolved })
    }

    @Test func capabilityParsingRequiresExactOptionsAndWords() {
        let oldStable = LumeBackend.capabilities(
            createHelp: "--unattended Tahoe --storage",
            runHelp: "--detach --storage --vnc-port --vnc-password disabled-ish",
            attachHelp: "--display native --storage"
        )
        #expect(oldStable.unattendedTahoe)
        #expect(oldStable.createRunAttachStorage)
        #expect(oldStable.detachedRun)
        #expect(oldStable.nativeAttach)
        #expect(!oldStable.vncCanBeDisabled, "--vnc-port and disabled-ish are not --vnc disabled")

        let misleadingSurface = LumeBackend.capabilities(
            createHelp: "--unattended tahoe --storage",
            runHelp: "--detach --storage --vnc disabled",
            attachHelp: "--display native --storage"
        )
        #expect(!misleadingSurface.vncCanBeDisabled, "the exact 0.5.3 pin has a fixed security verdict")
    }

    @Test func publicBackendRejectsABundleFromAnotherStorageRoot() throws {
        let firstStorage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let secondStorage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let bundleURL = LumeBundle.expectedLocation(in: firstStorage)
        let verified = try verifiedFixture(at: bundleURL)

        #expect(throws: LumeInvocationError.storageMismatch) {
            _ = try LumeBackend(bundle: verified, storage: secondStorage, runner: ScriptedLumeRunner(Self.successfulReplies))
        }
    }

    @Test func publicBackendRejectsAnAliasedBundlePath() throws {
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let expectedURL = LumeBundle.expectedLocation(in: storage)
        try FileManager.default.createDirectory(at: expectedURL, withIntermediateDirectories: true)
        let alias = storage.root.appending(path: "runtime-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: storage.url(for: .runtime))
        let aliasedURL = alias
            .appending(path: LumePin.releaseTag)
            .appending(path: LumePin.bundleName)
        let verified = try verifiedFixture(at: aliasedURL)

        #expect(throws: LumeInvocationError.storageMismatch) {
            _ = try LumeBackend(bundle: verified, storage: storage, runner: ScriptedLumeRunner(Self.successfulReplies))
        }
    }

    @Test func publicBackendReportsAChangedBundleAtTheExpectedPath() throws {
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let bundleURL = LumeBundle.expectedLocation(in: storage)
        let verified = try verifiedFixture(at: bundleURL)
        let originalIdentity = verified.verifiedFileIdentity.bundle.coordination
        try FileManager.default.removeItem(at: bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        #expect(RuntimeStorage.fileIdentity(of: bundleURL) != originalIdentity)

        #expect(throws: LumeInvocationError.bundleChanged) {
            _ = try LumeBackend(bundle: verified, storage: storage, runner: ScriptedLumeRunner(Self.successfulReplies))
        }
    }

    @Test func launchRevalidationRejectsAReplacedManagedAncestor() async throws {
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let bundleURL = LumeBundle.expectedLocation(in: storage)
        let verified = try verifiedFixture(at: bundleURL)
        let runner = ScriptedLumeRunner(Self.successfulReplies)
        let backend = try LumeBackend(bundle: verified, storage: storage, runner: runner)

        #expect(try LumeBackend.relocateForLaunch(verified, in: storage).url == bundleURL)

        let runtime = storage.url(for: .runtime)
        let movedRuntime = storage.root.appending(path: "runtime-before-link")
        try FileManager.default.moveItem(at: runtime, to: movedRuntime)
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: movedRuntime)

        #expect(throws: LumeInvocationError.bundleChanged) {
            try LumeBackend.relocateForLaunch(verified, in: storage)
        }
        await #expect(throws: LumeInvocationError.bundleChanged) { try await backend.probe() }
        #expect(await runner.invocations.isEmpty, "an ancestor swap is rejected before launch")
    }

    @Test func launchRevalidationRejectsAReplacedExecutableInsideTheSameBundle() async throws {
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let bundleURL = LumeBundle.expectedLocation(in: storage)
        let verified = try verifiedFixture(at: bundleURL)
        let runner = ScriptedLumeRunner(Self.successfulReplies)
        let backend = try LumeBackend(bundle: verified, storage: storage, runner: runner)
        let outerIdentity = RuntimeStorage.fileIdentity(of: bundleURL)

        let preservedExecutable = storage.url(for: .staging).appending(path: "lume-before-replacement")
        try FileManager.default.moveItem(at: verified.executable, to: preservedExecutable)
        try Data("replacement".utf8).write(to: verified.executable)

        #expect(RuntimeStorage.fileIdentity(of: bundleURL) == outerIdentity)
        #expect(!verified.matchesVerifiedFiles(in: LumeBundle(url: bundleURL)))
        #expect(throws: LumeInvocationError.bundleChanged) {
            try LumeBackend.relocateForLaunch(verified, in: storage)
        }
        await #expect(throws: LumeInvocationError.bundleChanged) { try await backend.probe() }
        #expect(await runner.invocations.isEmpty, "an inner executable swap is rejected before launch")
    }

    @Test func launchRevalidationRejectsAnInPlaceExecutableWrite() async throws {
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let bundleURL = LumeBundle.expectedLocation(in: storage)
        let verified = try verifiedFixture(at: bundleURL)
        let runner = ScriptedLumeRunner(Self.successfulReplies)
        let backend = try LumeBackend(bundle: verified, storage: storage, runner: runner)
        let executableIdentity = RuntimeStorage.fileIdentity(of: verified.executable)

        let handle = try FileHandle(forWritingTo: verified.executable)
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        #expect(RuntimeStorage.fileIdentity(of: verified.executable) == executableIdentity)
        #expect(!verified.matchesVerifiedFiles(in: LumeBundle(url: bundleURL)))
        #expect(throws: LumeInvocationError.bundleChanged) {
            try LumeBackend.relocateForLaunch(verified, in: storage)
        }
        await #expect(throws: LumeInvocationError.bundleChanged) { try await backend.probe() }
        #expect(await runner.invocations.isEmpty, "an in-place write is rejected before launch")
    }

    @Test func launchRevalidationRejectsAReplacementAtTheSamePath() async throws {
        let storage = try RuntimeStorage(root: root.appending(path: UUID().uuidString))
        let bundleURL = LumeBundle.expectedLocation(in: storage)
        let verified = try verifiedFixture(at: bundleURL)
        let runner = ScriptedLumeRunner(Self.successfulReplies)
        let backend = try LumeBackend(bundle: verified, storage: storage, runner: runner)

        try FileManager.default.removeItem(at: bundleURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        #expect(RuntimeStorage.fileIdentity(of: bundleURL) != verified.verifiedFileIdentity.bundle.coordination)
        #expect(throws: LumeInvocationError.bundleChanged) {
            try LumeBackend.relocateForLaunch(verified, in: storage)
        }
        await #expect(throws: LumeInvocationError.bundleChanged) { try await backend.probe() }
        #expect(await runner.invocations.isEmpty, "a replaced bundle is rejected before launch")
    }

    @Test func invocationErrorsAreActionable() {
        let failures: [LumeInvocationError] = [
            .storageMismatch,
            .bundleChanged,
            .failed(status: 1),
            .timedOut,
            .outputTruncated,
            .unparseableOutput,
            .versionMismatch(found: SemanticVersion([0, 5, 4]), required: LumePin.version),
        ]
        for failure in failures {
            #expect(failure.errorDescription == failure.userMessage)
            #expect(failure.localizedDescription == failure.userMessage)
            #expect(failure.recoveryActions == [.repair(.runtime), .cancel])
        }
    }

    @Test func processFailuresDoNotBecomeProbeResults() async throws {
        let canceledRunner = ScriptedLumeRunner(Self.successfulReplies)
        let (canceledBackend, _, _) = try backend(runner: canceledRunner)
        let canceledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await canceledBackend.probe()
        }
        await #expect(throws: CancellationError.self) { try await canceledTask.value }
        #expect(await canceledRunner.invocations.isEmpty, "a canceled probe launches nothing")

        let changedRunner = ScriptedLumeRunner(Self.successfulReplies)
        let (changedBackend, _, _) = try backend(runner: changedRunner) {
            throw LumeVerificationError.executableDigestMismatch
        }
        await #expect(throws: LumeInvocationError.bundleChanged) { try await changedBackend.probe() }
        #expect(await changedRunner.invocations.isEmpty, "changed code is rejected before launch")

        let launchFailingRunner = LaunchFailingLumeRunner()
        let verificationCount = Mutex(0)
        let (launchFailingBackend, _, _) = try backend(runner: launchFailingRunner) {
            try verificationCount.withLock {
                $0 += 1
                if $0 == 2 { throw LumeVerificationError.executableDigestMismatch }
            }
        }
        await #expect(throws: LumeInvocationError.bundleChanged) { try await launchFailingBackend.probe() }
        #expect(await launchFailingRunner.invocations.count == 1)
        #expect(verificationCount.withLock { $0 } == 2, "launch errors get a fresh verification")

        let badVersion = ScriptedLumeRunner(["--version": .init(stdout: ["lume 0.5.3"])])
        let (badVersionBackend, _, _) = try backend(runner: badVersion)
        await #expect(throws: LumeInvocationError.unparseableOutput) { try await badVersionBackend.probe() }

        let unexpectedVersion = ScriptedLumeRunner(["--version": .init(stdout: ["0.5.4"])])
        let (unexpectedVersionBackend, _, _) = try backend(runner: unexpectedVersion)
        await #expect(throws: LumeInvocationError.versionMismatch(found: SemanticVersion([0, 5, 4]), required: LumePin.version)) {
            try await unexpectedVersionBackend.probe()
        }
        #expect(await unexpectedVersion.invocations.count == 1, "a mismatched executable is not interrogated further")

        let nonzero = ScriptedLumeRunner(["--version": .init(stdout: [], stderr: ["opaque failure"], status: 17)])
        let (nonzeroBackend, _, _) = try backend(runner: nonzero)
        await #expect(throws: LumeInvocationError.failed(status: 17)) { try await nonzeroBackend.probe() }

        let truncated = ScriptedLumeRunner(["--version": .init(stdout: ["0.5.3"], outputTruncated: true)])
        let (truncatedBackend, _, _) = try backend(runner: truncated)
        await #expect(throws: LumeInvocationError.outputTruncated) { try await truncatedBackend.probe() }

        let (timedOutBackend, _, _) = try backend(runner: TimedOutLumeRunner())
        await #expect(throws: LumeInvocationError.timedOut) { try await timedOutBackend.probe() }
    }
}
