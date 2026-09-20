import Foundation
import GuesthouseCore
import Testing

struct EnvironmentCapabilitiesTests {
    private struct Fixture {
        let registry: RuntimeSessionRegistry<Bool>
        let id: EnvironmentID
        let generation: RuntimeSessionGeneration
        let tool: CapabilityToolIdentity
        var capabilities: EnvironmentCapabilities

        init() throws {
            let registry = RuntimeSessionRegistry<Bool>(incoming: { _ in }, interrupted: { _ in })
            let generation = try #require(registry.reserve())
            let tool = try CapabilityToolIdentity(tuple: CompatibilityTupleTests.tuple(), instanceID: UUID())
            let id = EnvironmentID()
            self.registry = registry
            self.generation = generation
            self.tool = tool
            self.id = id
            capabilities = EnvironmentCapabilities(environmentID: id, generation: generation)
            for capability in EnvironmentCapability.allCases { capabilities.setTool(tool, for: capability) }
        }

        var status: EnvironmentStatus { EnvironmentStatus(environmentID: id, vm: .running, readiness: .ready) }

        mutating func ready(_ capability: EnvironmentCapability) throws {
            let request = try #require(capabilities.begin(capability))
            #expect(capabilities.complete(request, environmentID: id, generation: generation, tool: tool, result: .ready))
        }
    }

    @Test(arguments: EnvironmentCapability.allCases)
    func missingEvidenceAndDecodedStatusAreNotLiveReadiness(_ capability: EnvironmentCapability) throws {
        let f = try Fixture()
        #expect(f.capabilities.state(of: capability) == .unknown)
        let data = try JSONEncoder().encode(f.status)
        let restored = try JSONDecoder().decode(EnvironmentStatus.self, from: data)
        #expect(restored == f.status)
        #expect(restored.capabilityAvailability(for: .guiAutomation, using: f.capabilities)
                == .blocked([.connection, .desktop, .guiAutomation]))
    }

    @Test func deniedGUILeavesShellBuildAndCredentialsIndependent() throws {
        var f = try Fixture()
        for capability in [EnvironmentCapability.connection, .buildTools, .credentials, .desktop] { try f.ready(capability) }
        let request = try #require(f.capabilities.begin(.guiAutomation))
        #expect(f.capabilities.complete(request, environmentID: f.id, generation: f.generation,
                                       tool: f.tool, result: .needsUserAction(.permissionRequired)))
        #expect(f.status.capabilityAvailability(for: .shell, using: f.capabilities) == .available)
        #expect(f.status.capabilityAvailability(for: .build, using: f.capabilities) == .available)
        #expect(f.status.capabilityAvailability(for: .authenticatedTools, using: f.capabilities) == .available)
        #expect(f.status.capabilityAvailability(for: .guiAutomation, using: f.capabilities) == .blocked([.guiAutomation]))
    }

    @Test(arguments: CapabilityInvalidation.allCases, [CapabilityState.ready, .unavailable(.inspectionFailed)])
    func invalidationRevokesPendingSuccessAndFailure(_ event: CapabilityInvalidation, _ result: CapabilityState) throws {
        var f = try Fixture()
        let old = try #require(f.capabilities.begin(.guiAutomation))
        f.capabilities.invalidate(event)
        #expect(!f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        #expect(f.capabilities.state(of: .guiAutomation) == .unknown)
        try f.ready(.guiAutomation)
        #expect(!f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        #expect(f.capabilities.state(of: .guiAutomation) == .ready)
    }

    @Test(arguments: [CapabilityState.ready, .unavailable(.inspectionFailed)])
    func supersededAndConsumedResultsCannotOverwriteNewEvidence(_ result: CapabilityState) throws {
        var f = try Fixture()
        let old = try #require(f.capabilities.begin(.desktop))
        try f.ready(.desktop)
        #expect(!f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        let current = try #require(f.capabilities.begin(.desktop))
        #expect(f.capabilities.state(of: .desktop) == .checking)
        #expect(f.capabilities.complete(current, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(!f.capabilities.complete(current, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        #expect(f.capabilities.state(of: .desktop) == .ready)
    }

    @Test func foreignEnvironmentSessionAndLedgerCannotPublish() throws {
        var f = try Fixture()
        var other = try Fixture()
        let request = try #require(f.capabilities.begin(.desktop))
        #expect(!f.capabilities.complete(request, environmentID: other.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(!f.capabilities.complete(request, environmentID: f.id, generation: other.generation, tool: f.tool, result: .ready))
        other.capabilities = EnvironmentCapabilities(environmentID: f.id, generation: f.generation)
        other.capabilities.setTool(f.tool, for: .desktop)
        #expect(!other.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(f.capabilities.state(of: .desktop) == .checking)
        #expect(f.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
    }

    @Test func reconnectRevokesEvenWhenHostSessionIsUnchanged() throws {
        var f = try Fixture()
        try f.ready(.buildTools)
        let request = try #require(f.capabilities.begin(.connection))
        f.capabilities.reconnect(generation: f.generation)
        #expect(f.capabilities.state(of: .buildTools) == .unknown)
        #expect(!f.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        try f.ready(.connection)
        #expect(f.capabilities.state(of: .connection) == .ready)
    }

    @Test func sameVersionToolReplacementRevokesOnlyAffectedCapability() throws {
        var f = try Fixture()
        try f.ready(.buildTools)
        let old = try #require(f.capabilities.begin(.guiAutomation))
        let replacement = try CapabilityToolIdentity(tuple: f.tool.tuple, instanceID: UUID())
        f.capabilities.setTool(replacement, for: .guiAutomation)
        #expect(!f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        let current = try #require(f.capabilities.begin(.guiAutomation))
        #expect(!f.capabilities.complete(current, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(f.capabilities.complete(current, environmentID: f.id, generation: f.generation, tool: replacement, result: .ready))
        #expect(f.capabilities.state(of: .buildTools) == .ready)
    }

    @Test func permissionsAndLockHaveDistinctInvalidationScopes() throws {
        var f = try Fixture()
        for capability in EnvironmentCapability.allCases { try f.ready(capability) }
        f.capabilities.invalidate(.permissionChange)
        #expect(f.capabilities.state(of: .desktop) == .ready)
        #expect(f.capabilities.state(of: .credentials) == .ready)
        #expect(f.capabilities.state(of: .guiAutomation) == .unknown)
        f.capabilities.invalidate(.lock)
        #expect(f.capabilities.state(of: .credentials) == .unknown)
        #expect(f.capabilities.state(of: .desktop) == .unknown)
        #expect(f.status.capabilityAvailability(for: .build, using: f.capabilities) == .available)
    }

    @Test(arguments: [CapabilityState.unknown, .checking])
    func nonterminalResultsDoNotConsumeRequest(_ result: CapabilityState) throws {
        var f = try Fixture()
        let request = try #require(f.capabilities.begin(.connection))
        #expect(!f.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        #expect(f.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
    }

    @Test(arguments: [EnvironmentStatus.VMState.stopped, .uncertain(reason: .operationOutcomeUnknown)])
    func observationsNeverOverrideUnknownOrStoppedRuntime(_ vm: EnvironmentStatus.VMState) throws {
        var f = try Fixture()
        for capability in EnvironmentCapability.allCases { try f.ready(capability) }
        let status = EnvironmentStatus(environmentID: f.id, vm: vm, readiness: .ready)
        #expect(status.capabilityAvailability(for: .guiAutomation, using: f.capabilities) == .requiresInspection)
        let inFlight = EnvironmentStatus(environmentID: f.id, vm: .running, readiness: .ready, inFlightOperation: OperationID())
        #expect(inFlight.capabilityAvailability(for: .build, using: f.capabilities) == .requiresInspection)
    }

    @Test func identityUsesExistingCompatibilityValidation() {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexCLIPath = "relative/tool"
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIPath)) {
            try CapabilityToolIdentity(tuple: tuple, instanceID: UUID())
        }
    }

    @Test func retiredGenerationCannotPublishOrDisplayOldReadiness() throws {
        var f = try Fixture()
        try f.ready(.connection)
        let old = try #require(f.capabilities.begin(.desktop))
        _ = f.registry.retire(f.generation)
        #expect(f.capabilities.state(of: .connection) == .unknown)
        #expect(f.capabilities.begin(.connection) == nil)
        #expect(!f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        let replacement = try #require(f.registry.reserve())
        f.capabilities.reconnect(generation: replacement)
        let current = try #require(f.capabilities.begin(.desktop))
        #expect(!f.capabilities.complete(old, environmentID: f.id, generation: replacement, tool: f.tool, result: .ready))
        #expect(f.capabilities.complete(current, environmentID: f.id, generation: replacement, tool: f.tool, result: .ready))
    }

    @Test(arguments: [CapabilityInvalidation.coldBoot, .reconnect, .wake], EnvironmentCapability.allCases)
    func globalLifecycleChangesClearEveryCapability(_ event: CapabilityInvalidation, _ capability: EnvironmentCapability) throws {
        var f = try Fixture()
        try f.ready(capability)
        f.capabilities.invalidate(event)
        #expect(f.capabilities.state(of: capability) == .unknown)
    }

    @Test func anUnconfiguredToolCannotStartAnObservation() throws {
        let f = try Fixture()
        var empty = EnvironmentCapabilities(environmentID: f.id, generation: f.generation)
        #expect(empty.begin(.connection) == nil)
        #expect(empty.state(of: .connection) == .unknown)
    }
}
