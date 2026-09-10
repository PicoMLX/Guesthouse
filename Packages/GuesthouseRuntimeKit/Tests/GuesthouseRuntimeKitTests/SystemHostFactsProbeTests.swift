import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

struct SystemHostFactsProbeTests {
    /// Read-only OS smoke test, not storage, application-account or VM hardware validation.
    /// No host-specific values are assumed.
    @Test func livePartialReaderLeavesUnimplementedChecksUnavailable() {
        let snapshot = SystemHostFactsProbe().snapshot()
        #expect(snapshot.disk == .unavailable(.storageRootUnknown))
        #expect(snapshot.codexDesktop == .unavailable)
        #expect(!PreflightCheck.run(snapshot: snapshot).canProceed)
    }

    @Test(arguments: [
        (SystemHostFactsProbe.ExecutableArchitecture.arm64, nil as Bool?, CPUArchitecture.appleSilicon),
        (.arm64, false, .appleSilicon), (.arm64, true, .appleSilicon),
        (.x86_64, true, .appleSilicon), (.x86_64, false, .intel), (.x86_64, nil, .unknown),
        (.unsupported, true, .unknown), (.unsupported, false, .unknown), (.unsupported, nil, .unknown),
    ])
    func nativeAndTranslatedArchitectureEvidence(_ values: (SystemHostFactsProbe.ExecutableArchitecture, Bool?, CPUArchitecture)) {
        #expect(SystemHostFactsProbe.architecture(executable: values.0, translated: values.1) == values.2)
    }

    @Test(arguments: [
        (Int32(0), Int32(0), Int32(0), 4, false as Bool?),
        (0, 0, 1, 4, true), (0, EACCES, 1, 4, true),
        (-1, ENOENT, 0, 4, false), (-1, ENOENT, 1, 0, false),
        (-1, EACCES, 0, 4, nil), (-1, EIO, 1, 4, nil),
        (0, 0, 2, 4, nil), (0, 0, -1, 4, nil),
        (0, 0, 1, 0, nil), (0, 0, 1, 8, nil), (1, 0, 1, 4, nil),
    ])
    func translationReadFailuresDoNotBecomeIntelEvidence(_ values: (Int32, Int32, Int32, Int, Bool?)) {
        #expect(SystemHostFactsProbe.translationStatus(status: values.0, error: values.1,
                                                        value: values.2, size: values.3) == values.4)
    }

    @Test(arguments: [
        (26, 4, 1, SemanticVersion([26, 4, 1]) as SemanticVersion?),
        (0, 0, 0, SemanticVersion([0])), (Int.max, Int.max, Int.max, SemanticVersion([Int.max, Int.max, Int.max])),
        (-1, 4, 1, nil), (26, -1, 1, nil), (26, 4, -1, nil),
    ])
    func operatingSystemComponentsAreCheckedBeforeConstructingAVersion(_ values: (Int, Int, Int, SemanticVersion?)) {
        let version = OperatingSystemVersion(majorVersion: values.0, minorVersion: values.1, patchVersion: values.2)
        #expect(SystemHostFactsProbe.version(version) == values.3)
    }

    @Test func missingOperatingSystemRemainsUnknown() {
        #expect(SystemHostFactsProbe.version(nil) == nil)
    }

    @Test(arguments: [
        ("AC Power" as String?, PowerSource.externalPower), ("Battery Power", .battery),
        ("UPS Power", .battery), (nil, .unknown), ("unrecognized native value", .unknown), ("", .unknown),
    ])
    func powerClassificationPreservesFiniteAndUnknownSources(_ values: (String?, PowerSource)) {
        #expect(SystemHostFactsProbe.powerSource(values.0) == values.1)
    }

    @Test(arguments: [nil as UInt64?, 0, 34_359_738_368, .max])
    func partialSnapshotNeverInventsDiskOrApplicationEvidence(memory: UInt64?) {
        let probe = fixture(executable: .x86_64, translated: true, memory: memory)
        let snapshot = probe.snapshot()
        #expect(snapshot.cpuArchitecture == .appleSilicon)
        #expect(snapshot.operatingSystemVersion == SemanticVersion([26, 4, 1]))
        #expect(snapshot.physicalMemoryBytes == memory)
        #expect(snapshot.powerSource == .battery)
        #expect(snapshot.disk == .unavailable(.storageRootUnknown))
        #expect(snapshot.codexDesktop == .unavailable)
        #expect(!PreflightCheck.run(snapshot: snapshot).canProceed)
    }

    @Test(arguments: [
        SystemHostFactsProbe.ExecutableArchitecture.arm64, .unsupported,
    ])
    func nonIntelExecutablesDoNotReadTheTranslationFlag(executable: SystemHostFactsProbe.ExecutableArchitecture) {
        let probe = SystemHostFactsProbe(executable: executable, source: .init(
            translated: { Issue.record("Translation flag must not be read for this executable."); return nil },
            operatingSystem: { nil }, physicalMemory: { nil }, power: { .unknown }
        ))
        #expect(probe.snapshot().operatingSystemVersion == nil)
    }

    @Test func instancesOwnTheirInputsAndMissingTranslationDoesNotBecomeAPass() {
        let native = fixture(executable: .x86_64, translated: false, memory: 16)
        let uncertain = fixture(executable: .x86_64, translated: nil, memory: nil)
        #expect(native.snapshot().cpuArchitecture == .intel)
        #expect(native.snapshot().physicalMemoryBytes == 16)
        #expect(uncertain.snapshot().cpuArchitecture == .unknown)
        #expect(uncertain.snapshot().physicalMemoryBytes == nil)
        #expect(!PreflightCheck.run(snapshot: uncertain.snapshot()).canProceed)
    }

    private func fixture(executable: SystemHostFactsProbe.ExecutableArchitecture,
                         translated: Bool?, memory: UInt64?) -> SystemHostFactsProbe {
        SystemHostFactsProbe(executable: executable, source: .init(
            translated: { translated },
            operatingSystem: { OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 1) },
            physicalMemory: { memory },
            power: { .battery }
        ))
    }
}
