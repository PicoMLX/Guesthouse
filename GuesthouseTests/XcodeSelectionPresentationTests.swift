import Foundation
import Testing
@testable import Guesthouse

struct XcodeSelectionPresentationTests {
    @Test @MainActor func everyUnsignedEstimateIsDisplayedWithoutTrappingOrBecomingUnknown() {
        let enormous = XcodeSelectionView.sizeDescription(for: .max)
        #expect(enormous.contains(UInt64.max.formatted()))
        #expect(!enormous.contains("could not"))
        #expect(XcodeSelectionView.sizeDescription(for: 4096).contains("4"))
        #expect(XcodeSelectionView.sizeDescription(for: nil) == "Disk usage could not be estimated.")
    }
}
