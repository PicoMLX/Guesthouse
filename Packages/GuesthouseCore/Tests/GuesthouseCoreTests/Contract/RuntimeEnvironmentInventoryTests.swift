import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeEnvironmentInventoryTests {
    @Test func unavailableMetadataAndEmptyLoadedInventoryRemainDistinct() throws {
        let records = [DevelopmentEnvironment(name: "App"), DevelopmentEnvironment(name: "Package")]
        let valid = [RuntimeEnvironmentInventory.available([]), .available(records)]
            + RuntimeSavedStateStatus.allCases.filter { $0 != .loaded }.map { .unavailable($0) }
        for inventory in valid {
            #expect(inventory.isValid)
            let envelope = RuntimeEventEnvelope(event: .environments(inventory))
            #expect(try RuntimeEventEnvelope.decode(envelope.encoded()) == envelope)
            #expect(envelope.event.diagnosticEvent == nil)
        }
        #expect(RuntimeEnvironmentInventory.available([]) != .unavailable(.unavailable))
        let request = RuntimeRequestEnvelope(request: .listEnvironments)
        #expect(try RequestValidator.decode(JSONEncoder().encode(request)) == request)
    }

    @Test func invalidCountsIdentitiesVersionsAndOversizedNamesAreRefusedBothWays() throws {
        let record = DevelopmentEnvironment(name: "App")
        let invalid: [RuntimeEnvironmentInventory] = [
            .unavailable(.loaded), .available([record, record]),
            .available((0..<3).map { DevelopmentEnvironment(name: "App \($0)") }),
            .available([DevelopmentEnvironment(name: "App", schemaVersion: SchemaVersion(99)!)]),
            .available([DevelopmentEnvironment(name: String(repeating: "a", count: 1025))])
        ]
        for inventory in invalid {
            #expect(!inventory.isValid)
            let envelope = RuntimeEventEnvelope(event: .environments(inventory))
            #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try envelope.encoded() }
            let bytes = try JSONEncoder().encode(envelope)
            #expect(throws: GuesthouseError.invalidRuntimeReply(.malformed)) { try RuntimeEventEnvelope.decode(bytes) }
        }
    }

    @Test func fakeInventoryIsExplicitAndNeverAnOperationAcceptance() async throws {
        let backend = FakeRuntimeBackend()
        let inventory = RuntimeEnvironmentInventory.unavailable(.repairRequired)
        await backend.setEnvironmentInventory(inventory)
        var events: [RuntimeEvent] = []
        for try await event in backend.send(.listEnvironments) { events.append(event) }
        #expect(events == [.environments(inventory)])
        #expect(await backend.receivedRequests == [.listEnvironments])
    }
}
