import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

struct DiagnosticsSelectionTests {
    @Test func copyingUsesVisibleSelectionAndLocallyRenderedRecoveryOnly() {
        var log = DiagnosticLog()
        let included = UUID(), excluded = UUID()
        log.append(.init(operation: .startEnvironment, outcome: .operationFailed(.runtimeMissing), operationID: included))
        log.append(.init(operation: .stopEnvironment, outcome: .succeeded, operationID: excluded))
        let filtered = DiagnosticsSelection.records(in: log, matching: "not installed")
        #expect(filtered.count == 1 && filtered[0].event.operationID == included)
        let text = DiagnosticsSelection.text(in: log, matching: "not installed", selection: [0, 99])
        #expect(text?.contains(included.uuidString) == true && text?.contains(excluded.uuidString) == false)
        #expect(text?.contains(GuesthouseError.runtimeMissing.recoveryMessage) == true)
        #expect(DiagnosticsSelection.text(in: log, matching: "not installed", selection: [1]) == nil)
        #expect(DiagnosticsSelection.text(in: log, matching: "", selection: []) == nil)
    }
}
