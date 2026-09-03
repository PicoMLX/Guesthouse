import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

struct StubHostProbe: HostProbe {
    var cpuArchitecture: CPUArchitecture = .appleSilicon
    var operatingSystemVersion = SemanticVersion([26, 5, 2])
    var operatingSystemBuild: String? = "25F84"
    var physicalMemoryBytes: UInt64 = 32 * ResourcePreset.gibibyte
    var powerSource: PowerSource = .externalPower
    var free: UInt64 = 500 * ResourcePreset.gigabyte
    var applications: [String: InstalledApplication] = ["com.openai.chat": InstalledApplication(url: URL(fileURLWithPath: "/Applications/ChatGPT.app"), version: "1.2.3", build: "456")]

    var freeThrows = false

    struct ProbeFailure: Error {}

    func freeBytes(at url: URL) throws -> UInt64 {
        if freeThrows { throw ProbeFailure() }
        return free
    }
    func installedApplication(bundleIdentifier: String) -> InstalledApplication? { applications[bundleIdentifier] }
}

@MainActor
@Suite struct SetupWizardTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "SetupWizardTests-\(UUID().uuidString)")! }

    func checked(_ probe: StubHostProbe) async -> CheckThisMacModel {
        let model = CheckThisMacModel(probe: probe, storageRoot: URL(fileURLWithPath: "/Users/dev/Library/Application Support/Guesthouse"))
        model.check()
        for _ in 0..<400 where model.report == nil { try? await Task.sleep(for: .milliseconds(5)) }
        return model
    }

    @Test func checkingAgainWithdrawsThePassingReportUntilTheNewOneArrives() async {
        let model = await checked(StubHostProbe())
        #expect(model.canProceed)
        model.check()
        #expect(model.isChecking)
        #expect(!model.canProceed, "Next waits for the fresh result")
        for _ in 0..<400 where model.isChecking { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.canProceed)
    }

    @Test func anUnreadableVolumeStopsSetupInsteadOfWarning() async {
        var probe = StubHostProbe(); probe.freeThrows = true
        let model = await checked(probe)
        #expect(!model.canProceed, "an unanswered question is not a satisfied requirement")
        guard let disk = model.rows.first(where: { $0.kind == .freeDisk }) else { Issue.record("no disk row"); return }
        #expect(disk.verdict == .undetermined)
        #expect(disk.recovery.contains { $0.action == .retry })
    }

    @Test func dismissBecomesAWorkingCloseSetupInsideACheckRow() {
        let options = [RecoveryPresentation.option(for: .cancel, outcomeUnknown: false), RecoveryPresentation.option(for: .retry, outcomeUnknown: false)]
        let presented = CheckThisMacModel.presentable(options)
        #expect(presented.map(\.action) == [.cancel, .retry])
        #expect(presented.first?.title == "Close setup")
        #expect(presented.first?.availability == .enabled)
    }

    @Test func aCheckWithOnlyACancelActionStillOffersOne() async {
        let model = await checked(StubHostProbe(cpuArchitecture: .intel))
        guard let architecture = model.rows.first(where: { $0.kind == .architecture }) else { Issue.record("no architecture row"); return }
        #expect(architecture.verdict == .fail)
        #expect(architecture.recovery.map(\.title) == ["Close setup"])
    }

    @Test func allPassEnablesNextAndSummarizesStorage() async {
        let model = await checked(StubHostProbe())
        #expect(model.canProceed)
        #expect(model.rows.count == PreflightCheckKind.allCases.count)
        #expect(model.rows.allSatisfy { $0.verdict == .pass && $0.recovery.isEmpty && !$0.detail.isEmpty })
        #expect(model.storageSummary.contains { $0.contains("/Users/dev/Library/Application Support/Guesthouse") })
        #expect(model.storageSummary.contains { $0.contains("restore image") })
        let wizard = SetupWizardModel(defaults: defaults(), checkThisMac: model)
        #expect(wizard.current == .checkThisMac)
        #expect(!wizard.canGoBack)
        #expect(wizard.canGoNext)
    }

    @Test func warningsOnlyStillAllowNextAndCarryRecovery() async {
        // Above the floor (the guest's allocation plus the host's headroom) but below what
        // Guesthouse recommends: a warning, not a refusal.
        let model = await checked(StubHostProbe(physicalMemoryBytes: 28 * ResourcePreset.gibibyte, powerSource: .battery, applications: [:]))
        #expect(model.canProceed)
        let warnings = model.rows.filter { $0.verdict == .warn }
        #expect(warnings.map(\.kind).contains(.codexDesktop))
        #expect(warnings.allSatisfy { !$0.detail.isEmpty })
        #expect(warnings.first { $0.kind == .codexDesktop }?.detail.contains("not installed") == true)
        #expect(model.storageSummary.contains { $0.contains("battery") })
        #expect(SetupWizardModel(defaults: defaults(), checkThisMac: model).canGoNext)
    }

    @Test func aFailureDisablesNextAndOffersRecovery() async {
        let model = await checked(StubHostProbe(cpuArchitecture: .intel, free: 20 * ResourcePreset.gigabyte))
        #expect(!model.canProceed)
        let failures = model.rows.filter { $0.verdict == .fail }
        #expect(failures.map(\.kind) == [.architecture, .freeDisk])
        #expect(failures.allSatisfy { !$0.recovery.isEmpty && !$0.detail.isEmpty })
        let wizard = SetupWizardModel(defaults: defaults(), checkThisMac: model)
        #expect(!wizard.canGoNext)
        wizard.next()
        #expect(wizard.current == .checkThisMac, "Next is refused while a check fails")
    }

    @Test func theStageIsPersistedAndResumed() async {
        let store = defaults()
        let model = await checked(StubHostProbe())
        let wizard = SetupWizardModel(defaults: store, checkThisMac: model)
        wizard.next()
        #expect(wizard.current == .createDevelopmentMac)
        #expect(!wizard.canGoNext, "an unimplemented stage cannot be completed")
        #expect(wizard.canGoBack)
        let resumed = SetupWizardModel(defaults: store, checkThisMac: model)
        #expect(resumed.current == .createDevelopmentMac)
        resumed.back()
        #expect(resumed.current == .checkThisMac)
        #expect(SetupWizardModel(defaults: store, checkThisMac: model).current == .checkThisMac)
        #expect(SetupStage.allCases.count == 8)
        #expect(SetupStage.allCases.filter(\.isImplemented) == [.checkThisMac])
    }
}
