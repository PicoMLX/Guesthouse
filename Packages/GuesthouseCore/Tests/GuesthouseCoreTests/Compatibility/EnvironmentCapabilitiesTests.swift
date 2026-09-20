import Foundation
import GuesthouseCore
import Testing

struct EnvironmentCapabilitiesTests {
    private struct Fixture: Sendable {
        let registry: RuntimeSessionRegistry<Bool>
        let id: EnvironmentID
        let generation: RuntimeSessionGeneration
        let tool: CapabilityToolIdentity
        var capabilities: EnvironmentCapabilities

        init() async throws {
            let registry = RuntimeSessionRegistry<Bool>(incoming: { _ in }, interrupted: { _ in })
            let generation = try #require(registry.reserve())
            #expect(registry.install(true, for: generation))
            #expect(registry.activated(generation))
            let tool = try CapabilityToolIdentity(tuple: CompatibilityTupleTests.tuple(), instanceID: UUID())
            let id = EnvironmentID()
            self.registry = registry
            self.generation = generation
            self.tool = tool
            self.id = id
            capabilities = EnvironmentCapabilities(environmentID: id, registry: registry)
            for capability in EnvironmentCapability.allCases { await capabilities.setTool(tool, for: capability) }
        }

        var status: EnvironmentStatus { EnvironmentStatus(environmentID: id, vm: .running, readiness: .ready) }

        func ready(_ capability: EnvironmentCapability) async throws {
            let request = try #require(await capabilities.begin(capability))
            #expect(await capabilities.complete(request, environmentID: id, generation: generation, tool: tool, result: .ready))
        }
    }

    @Test(arguments: EnvironmentCapability.allCases)
    func missingEvidenceAndDecodedStatusAreNotLiveReadiness(_ capability: EnvironmentCapability) async throws {
        let f = try await Fixture()
        #expect(await f.capabilities.state(of: capability) == .unknown)
        let data = try JSONEncoder().encode(f.status)
        let restored = try JSONDecoder().decode(EnvironmentStatus.self, from: data)
        #expect(restored == f.status)
        #expect(await restored.capabilityAvailability(for: .guiAutomation, using: f.capabilities)
                == .blocked([.connection, .desktop, .guiAutomation]))
    }

    @Test func deniedGUILeavesShellBuildAndCredentialsIndependent() async throws {
        let f = try await Fixture()
        for capability in [EnvironmentCapability.connection, .buildTools, .credentials, .desktop] { try await f.ready(capability) }
        let request = try #require(await f.capabilities.begin(.guiAutomation))
        #expect(await f.capabilities.complete(request, environmentID: f.id, generation: f.generation,
                                       tool: f.tool, result: .needsUserAction(.permissionRequired)))
        #expect(await f.status.capabilityAvailability(for: .shell, using: f.capabilities) == .available)
        #expect(await f.status.capabilityAvailability(for: .build, using: f.capabilities) == .available)
        #expect(await f.status.capabilityAvailability(for: .authenticatedTools, using: f.capabilities) == .available)
        #expect(await f.status.capabilityAvailability(for: .guiAutomation, using: f.capabilities) == .blocked([.guiAutomation]))
    }

    @Test(arguments: CapabilityInvalidation.allCases, [CapabilityState.ready, .unavailable(.inspectionFailed)])
    func invalidationRevokesPendingSuccessAndFailure(_ event: CapabilityInvalidation, _ result: CapabilityState) async throws {
        let f = try await Fixture()
        let old = try #require(await f.capabilities.begin(.guiAutomation))
        await f.capabilities.invalidate(event)
        #expect(await !f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        #expect(await f.capabilities.state(of: .guiAutomation) == .unknown)
        try await f.ready(.guiAutomation)
        #expect(await !f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        #expect(await f.capabilities.state(of: .guiAutomation) == .ready)
    }

    @Test(arguments: [CapabilityState.ready, .unavailable(.inspectionFailed)])
    func supersededAndConsumedResultsCannotOverwriteNewEvidence(_ result: CapabilityState) async throws {
        let f = try await Fixture()
        let old = try #require(await f.capabilities.begin(.desktop))
        try await f.ready(.desktop)
        #expect(await !f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        let current = try #require(await f.capabilities.begin(.desktop))
        #expect(await f.capabilities.state(of: .desktop) == .checking)
        #expect(await f.capabilities.complete(current, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(await !f.capabilities.complete(current, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        #expect(await f.capabilities.state(of: .desktop) == .ready)
    }

    @Test func foreignEnvironmentSessionAndLedgerCannotPublish() async throws {
        let f = try await Fixture()
        var other = try await Fixture()
        let request = try #require(await f.capabilities.begin(.desktop))
        #expect(await !f.capabilities.complete(request, environmentID: other.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(await !f.capabilities.complete(request, environmentID: f.id, generation: other.generation, tool: f.tool, result: .ready))
        other.capabilities = EnvironmentCapabilities(environmentID: f.id, registry: f.registry)
        await other.capabilities.setTool(f.tool, for: .desktop)
        #expect(await !other.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(await f.capabilities.state(of: .desktop) == .checking)
        #expect(await f.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
    }

    @Test func reconnectRevokesEvenWhenHostSessionIsUnchanged() async throws {
        let f = try await Fixture()
        try await f.ready(.buildTools)
        let request = try #require(await f.capabilities.begin(.connection))
        await f.capabilities.reconnect()
        #expect(await f.capabilities.state(of: .buildTools) == .unknown)
        #expect(await !f.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        try await f.ready(.connection)
        #expect(await f.capabilities.state(of: .connection) == .ready)
    }

    @Test func sameVersionToolReplacementRevokesOnlyAffectedCapability() async throws {
        let f = try await Fixture()
        try await f.ready(.buildTools)
        let old = try #require(await f.capabilities.begin(.guiAutomation))
        let replacement = try CapabilityToolIdentity(tuple: f.tool.tuple, instanceID: UUID())
        await f.capabilities.setTool(replacement, for: .guiAutomation)
        #expect(await !f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        let current = try #require(await f.capabilities.begin(.guiAutomation))
        #expect(await !f.capabilities.complete(current, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(await f.capabilities.complete(current, environmentID: f.id, generation: f.generation, tool: replacement, result: .ready))
        #expect(await f.capabilities.state(of: .buildTools) == .ready)
    }

    @Test func permissionsAndLockHaveDistinctInvalidationScopes() async throws {
        let f = try await Fixture()
        for capability in EnvironmentCapability.allCases { try await f.ready(capability) }
        await f.capabilities.invalidate(.permissionChange)
        #expect(await f.capabilities.state(of: .desktop) == .ready)
        #expect(await f.capabilities.state(of: .credentials) == .ready)
        #expect(await f.capabilities.state(of: .guiAutomation) == .unknown)
        await f.capabilities.invalidate(.lock)
        #expect(await f.capabilities.state(of: .credentials) == .unknown)
        #expect(await f.capabilities.state(of: .desktop) == .unknown)
        #expect(await f.status.capabilityAvailability(for: .build, using: f.capabilities) == .available)
    }

    @Test(arguments: [CapabilityState.unknown, .checking])
    func nonterminalResultsDoNotConsumeRequest(_ result: CapabilityState) async throws {
        let f = try await Fixture()
        let request = try #require(await f.capabilities.begin(.connection))
        #expect(await !f.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: result))
        #expect(await f.capabilities.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
    }

    @Test(arguments: [EnvironmentStatus.VMState.stopped, .uncertain(reason: .operationOutcomeUnknown)])
    func observationsNeverOverrideUnknownOrStoppedRuntime(_ vm: EnvironmentStatus.VMState) async throws {
        let f = try await Fixture()
        for capability in EnvironmentCapability.allCases { try await f.ready(capability) }
        let status = EnvironmentStatus(environmentID: f.id, vm: vm, readiness: .ready)
        #expect(await status.capabilityAvailability(for: .guiAutomation, using: f.capabilities) == .requiresInspection)
        let inFlight = EnvironmentStatus(environmentID: f.id, vm: .running, readiness: .ready, inFlightOperation: OperationID())
        #expect(await inFlight.capabilityAvailability(for: .build, using: f.capabilities) == .requiresInspection)
    }

    @Test func identityUsesExistingCompatibilityValidation() {
        var tuple = CompatibilityTupleTests.tuple()
        tuple.codexCLIPath = "relative/tool"
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIPath)) {
            try CapabilityToolIdentity(tuple: tuple, instanceID: UUID())
        }
    }

    @Test func retiredGenerationCannotPublishOrDisplayOldReadiness() async throws {
        let f = try await Fixture()
        try await f.ready(.connection)
        let old = try #require(await f.capabilities.begin(.desktop))
        _ = f.registry.retire(f.generation)
        #expect(await f.capabilities.state(of: .connection) == .unknown)
        #expect(await f.capabilities.begin(.connection) == nil)
        #expect(await !f.capabilities.complete(old, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        let replacement = try #require(f.registry.reserve())
        #expect(f.registry.install(true, for: replacement))
        #expect(f.registry.activated(replacement))
        await f.capabilities.reconnect()
        let current = try #require(await f.capabilities.begin(.desktop))
        #expect(await !f.capabilities.complete(old, environmentID: f.id, generation: replacement, tool: f.tool, result: .ready))
        #expect(await f.capabilities.complete(current, environmentID: f.id, generation: replacement, tool: f.tool, result: .ready))
    }

    @Test(arguments: [CapabilityInvalidation.coldBoot, .reconnect, .wake], EnvironmentCapability.allCases)
    func globalLifecycleChangesClearEveryCapability(_ event: CapabilityInvalidation, _ capability: EnvironmentCapability) async throws {
        let f = try await Fixture()
        try await f.ready(capability)
        await f.capabilities.invalidate(event)
        #expect(await f.capabilities.state(of: capability) == .unknown)
    }

    @Test func anUnconfiguredToolCannotStartAnObservation() async throws {
        let f = try await Fixture()
        let empty = EnvironmentCapabilities(environmentID: f.id, registry: f.registry)
        #expect(await empty.begin(.connection) == nil)
        #expect(await empty.state(of: .connection) == .unknown)
    }

    @Test(arguments: [CapabilityInvalidation.wake, .reconnect, .permissionChange])
    func aliasesShareRevocationAndCannotRestoreOldReadiness(_ event: CapabilityInvalidation) async throws {
        let f = try await Fixture()
        let alias = f.capabilities
        let request = try #require(await alias.begin(.guiAutomation))
        await f.capabilities.invalidate(event)
        #expect(await !alias.complete(request, environmentID: f.id, generation: f.generation, tool: f.tool, result: .ready))
        #expect(await alias.state(of: .guiAutomation) == .unknown)
        try await f.ready(.guiAutomation)
        #expect(await alias.state(of: .guiAutomation) == .ready)
    }

    @Test func reservationAndInstallationDoNotAuthorizeChecks() async throws {
        let f = try await Fixture()
        let registry = RuntimeSessionRegistry<Bool>(incoming: { _ in }, interrupted: { _ in })
        let generation = try #require(registry.reserve())
        let ledger = EnvironmentCapabilities(environmentID: f.id, registry: registry)
        await ledger.setTool(f.tool, for: .connection)
        #expect(await ledger.begin(.connection) == nil)
        #expect(registry.install(true, for: generation))
        await ledger.reconnect()
        #expect(await ledger.begin(.connection) == nil)
        #expect(registry.activated(generation))
        #expect(await ledger.begin(.connection) == nil)
        await ledger.reconnect()
        let request = try #require(await ledger.begin(.connection))
        #expect(await ledger.complete(request, environmentID: f.id, generation: generation, tool: f.tool, result: .ready))
        _ = registry.retire(generation)
        #expect(await ledger.state(of: .connection) == .unknown)
    }

    @Test func missingToolsCanReportUnavailableWithoutInventedVersions() async throws {
        let f = try await Fixture()
        try await f.ready(.connection)
        let probe = try CapabilityToolIdentity(instanceID: UUID())
        #expect(probe.tuple == nil)
        await f.capabilities.setTool(probe, for: .buildTools)
        let request = try #require(await f.capabilities.begin(.buildTools))
        #expect(await f.capabilities.complete(request, environmentID: f.id, generation: f.generation,
                                              tool: probe, result: .unavailable(.toolUnavailable)))
        #expect(await f.status.capabilityAvailability(for: .build, using: f.capabilities) == .blocked([.buildTools]))
        await f.capabilities.setTool(f.tool, for: .buildTools)
        #expect(await f.capabilities.state(of: .buildTools) == .unknown)
        try await f.ready(.buildTools)
        #expect(await f.status.capabilityAvailability(for: .build, using: f.capabilities) == .available)
    }

    @Test func expiredDeniedOrWrongAccountHasSignInRecovery() async throws {
        let f = try await Fixture()
        let request = try #require(await f.capabilities.begin(.credentials))
        #expect(await f.capabilities.complete(request, environmentID: f.id, generation: f.generation,
                                              tool: f.tool, result: .needsUserAction(.signInRequired)))
        #expect(await f.capabilities.state(of: .credentials) == .needsUserAction(.signInRequired))
        #expect(CapabilityReason.signInRequired.recoveryActions == [.signInAgain, .cancel])
        #expect(CapabilityReason.signInRequired.userMessage.contains("intended account"))
    }

    @Test func concurrentCompletionsHaveOnePublicationOwner() async throws {
        let f = try await Fixture()
        let request = try #require(await f.capabilities.begin(.desktop))
        async let ready = f.capabilities.complete(request, environmentID: f.id, generation: f.generation,
                                                  tool: f.tool, result: .ready)
        async let failed = f.capabilities.complete(request, environmentID: f.id, generation: f.generation,
                                                   tool: f.tool, result: .unavailable(.inspectionFailed))
        let (acceptedReady, acceptedFailure) = await (ready, failed)
        #expect(acceptedReady != acceptedFailure)
        let expected: CapabilityState = acceptedReady ? .ready : .unavailable(.inspectionFailed)
        #expect(await f.capabilities.state(of: .desktop) == expected)
    }
}
