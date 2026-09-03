import Testing
@testable import GuesthouseCore

@Suite struct ResourcePresetTests {
    @Test func recommendedPresetMatchesPlanBaselineFor32GBHost() {
        let preset = ResourcePreset.recommended
        #expect(preset.memoryBytes >= 14 * ResourcePreset.gibibyte)
        #expect(preset.memoryBytes <= 16 * ResourcePreset.gibibyte)
        #expect(preset.diskBytes == 160 * ResourcePreset.gigabyte)
        #expect(preset.verification == .planBaseline)
    }

    @Test func dualVMPresetIsExplicitlyExperimental() {
        let preset = ResourcePreset.dualVMExperiment
        #expect(preset.verification == .experimental)
        #expect(preset.memoryBytes == 12 * ResourcePreset.gibibyte)
        #expect(2 * preset.memoryBytes < 32 * ResourcePreset.gibibyte)
    }
}
