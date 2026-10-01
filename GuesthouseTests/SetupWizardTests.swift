import Foundation
import GuesthouseClientKit
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor @Suite(.timeLimit(.minutes(1))) struct SetupWizardTests {
    nonisolated static func report(_ severity: PreflightResult.Severity) -> PreflightReport {
        let memory: PreflightResult = switch severity {
        case .pass: .memorySufficient(bytes: 32_000_000_000)
        case .warn: .memoryLimited(foundBytes: 16_000_000_000, recommendedBytes: 32_000_000_000)
        case .fail: .memoryFailure(.unsupportedHost(.insufficientMemory(foundBytes: 1, minimumBytes: 2)))
        case .undetermined: .memoryUnknown
        }
        return .init(results: [.architectureSupported(.appleSilicon), .macOSSupported(SemanticVersion("26.6")!), memory,
            .diskSufficient(bytes: 300_000_000_000), severity == .warn ? .codexNotFound : .codexInstalled(version: nil, build: nil)], storage: .init(), powerSource: severity == .warn ? .battery : .externalPower, checkedAt: Date())
    }
    @Test(arguments: [PreflightResult.Severity.pass, .warn, .fail, .undetermined])
    func nextRequiresACompleteNonblockingFreshReport(severity: PreflightResult.Severity) async throws {
        let suite = "GuesthouseWizardTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let host = HostPreflightModel { .success(Self.report(severity)) }
        let wizard = SetupWizardModel(defaults: defaults, host: host)
        #expect(!wizard.canGoNext)
        wizard.next(); #expect(wizard.stage == .checkThisMac)
        await host.check().value
        #expect(wizard.canGoNext == (severity == .pass || severity == .warn))
        wizard.next()
        #expect(wizard.stage == (severity == .pass || severity == .warn ? .createDevelopmentMac : .checkThisMac))
        #expect(!wizard.canGoNext)
    }
    @Test func navigationResumesWithoutRestoringPassedChecksOrEnablingPlaceholders() async throws {
        let suite = "GuesthouseWizardTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let wizard = SetupWizardModel(defaults: defaults, host: HostPreflightModel { .success(Self.report(.pass)) })
        await wizard.host.check().value; wizard.next()
        let resumed = SetupWizardModel(defaults: defaults)
        #expect(resumed.stage == .createDevelopmentMac && !resumed.canGoNext)
        resumed.next(); #expect(resumed.stage == .createDevelopmentMac)
        resumed.back(); #expect(resumed.stage == .checkThisMac && !resumed.canGoNext)
        defaults.set("unknown future stage", forKey: SetupWizardModel.stageKey)
        #expect(SetupWizardModel(defaults: defaults).stage == .checkThisMac)
    }
    @Test func queryFailureAndIncompleteReportNeverEnableNext() async {
        let failed = HostPreflightModel { .failure(.timedOut) }
        await failed.check().value; #expect(!failed.canProceed)
        let incomplete = HostPreflightModel { .success(.init(results: [], storage: .init(), powerSource: .unknown, checkedAt: Date())) }
        await incomplete.check().value; #expect(!incomplete.canProceed)
    }
    @Test func canceledQueryDrainsBeforeAnotherCheckAndCannotPublishItsLateSuccess() async {
        let gate = HostQueryGate(), model = HostPreflightModel(query: { await gate.run() })
        var started = gate.started.makeAsyncIterator()
        let first = model.check(); _ = await started.next()
        model.cancel()
        #expect(model.isChecking && model.cancellationRequested && !model.canProceed)
        let joined = model.check()
        #expect(await gate.count == 1)
        await gate.finish(.success(Self.report(.pass)))
        await first.value; await joined.value
        #expect(!model.isChecking && !model.canProceed)
        #expect(model.outcome == .failure(.canceled))
    }
}

private actor HostQueryGate {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var reply: CheckedContinuation<RuntimeHostPreflightQuery.Outcome, Never>?
    private(set) var count = 0
    init() { (started, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func run() async -> RuntimeHostPreflightQuery.Outcome {
        count += 1
        return await withCheckedContinuation { reply = $0; signal.yield(()) }
    }
    func finish(_ outcome: RuntimeHostPreflightQuery.Outcome) { reply?.resume(returning: outcome); reply = nil; signal.finish() }
}
