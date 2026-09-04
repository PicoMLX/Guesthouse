import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@Suite struct DebugRuntimeProbeTests {
    @Test @MainActor func anEstimateTooLargeForTheFormatterIsShownNotTrappedOn() {
        // The service reports the estimate as a `UInt64`; the formatter takes an `Int64`. A
        // bundle measured above `Int64.max` — a large file provider, or a tree of links to one
        // enormous file — must be displayed, not crash the app on the conversion.
        let enormous = XcodeCandidate(version: "26.6", build: "17F113", path: "/Applications/Xcode.app", sizeEstimateBytes: UInt64.max)
        let described = DebugRuntimeProbe.describe(enormous)
        #expect(described.contains("Xcode 26.6 (17F113)"))
        #expect(!described.contains("unknown size"))

        let ordinary = XcodeCandidate(version: "26.6", build: "17F113", path: "/Applications/Xcode.app", sizeEstimateBytes: 4_096)
        #expect(DebugRuntimeProbe.describe(ordinary).contains("4"))
        let unmeasured = XcodeCandidate(version: "26.6", build: "17F113", path: "/Applications/Xcode.app", sizeEstimateBytes: nil)
        #expect(DebugRuntimeProbe.describe(unmeasured).contains("unknown size"))
    }
}
