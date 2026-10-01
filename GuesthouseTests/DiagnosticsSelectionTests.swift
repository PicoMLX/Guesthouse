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
    @Test func copiedRowsKeepSourceEvictionsAndEnvironmentAttribution() throws {
        let environment = EnvironmentID()
        var log = DiagnosticLog(capacity: 1)
        let event = DiagnosticEvent(operation: .startEnvironment, outcome: .started, operationID: UUID(), environmentID: environment)
        log.append(event); log.append(event)
        let text = try #require(DiagnosticsSelection.text(in: log, matching: environment.description, selection: [0]))
        #expect(text.contains("Older/omitted events: 1."))
        #expect(text.contains(DiagnosticsExportBuilder.historyNotice) && text.contains(environment.description))
        #expect(!text.contains("Older/omitted events: 0."))
    }

}
