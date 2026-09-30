import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct RuntimeEnvironmentInspectorTests {
    let environment = DevelopmentEnvironment(name: "Saved work")
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    var identity: ProcessIdentity {
        ProcessIdentity(pid: 123, startTime: Date(timeIntervalSince1970: 1_800_000_000),
            executablePath: "/test/provider", argumentsDigest: "sha256:" + String(repeating: "a", count: 64),
            vmName: environment.id.managedVMName, environmentID: environment.id, recordedAt: now)
    }
    var journal: JournalReplay { JournalReplay(records: [], inFlight: [:], truncatedTail: false) }
    func snapshot() throws -> EnvironmentsSnapshot {
        var slots = VMSlotInventory()
        try slots.reserve(environment.id)
        return EnvironmentsSnapshot(environments: [environment], slots: slots, processIdentities: [environment.id: identity])
    }
    func live() -> LiveProcess {
        LiveProcess(pid: identity.pid, startTime: identity.startTime, executablePath: identity.executablePath,
            argumentsDigest: identity.argumentsDigest, claimedVMName: identity.vmName)
    }

    @Test(arguments: ["owned", "exited", "reused", "unreadable", "lock", "claim", "competitor"])
    func projectsOnlyReconciledOwnershipAndNeverReadiness(kind: String) throws {
        var evidence = RuntimeEnvironmentInspector.Evidence(processes: [live()], complete: true, lockPresent: true)
        let expected: EnvironmentStatus.VMState
        switch kind {
        case "owned": expected = .running
        case "exited": evidence.processes = []; evidence.lockPresent = false; expected = .stopped
        case "reused": evidence.processes[0].startTime = now; expected = .uncertain(reason: .processIdentityChanged)
        case "unreadable": evidence.complete = false; expected = .uncertain(reason: .inspectionFailed)
        case "lock": evidence.lockPresent = nil; expected = .uncertain(reason: .inspectionFailed)
        case "claim": evidence.processes[0].claimedVMName = nil; expected = .uncertain(reason: .ownershipUnproven)
        default:
            var other = live(); other.pid += 1; evidence.processes.append(other)
            expected = .uncertain(reason: .ownershipUnproven)
        }
        let observed = evidence
        let inspector = RuntimeEnvironmentInspector(inspect: { _ in observed })
        let result = inspector.status(for: environment.id, snapshot: try snapshot(), journal: journal, metadataUsable: true, now: now)
        #expect(result.vm == expected)
        #expect(result.readiness == .checking)
        #expect(result.observed == ObservedTuple())
        #expect(result.inFlightOperation == nil)
        #expect(result.reconciledAt == (["owned", "exited"].contains(kind) ? now : nil))
    }

    @Test(arguments: ["pending", "tail", "metadata", "missingIdentity", "unknownEnvironment"])
    func incompleteSavedStateCannotBeOverriddenByAProvider(kind: String) throws {
        let calls = Mutex(0)
        let inspector = RuntimeEnvironmentInspector(inspect: { _ in calls.withLock { $0 += 1 }; return .unavailable })
        var snapshot = try snapshot(), history = journal
        let pending = JournalRecord(id: OperationID(), environmentID: environment.id, operation: .importXcode, timestamp: now, outcome: .unknown)
        if kind == "pending" { history.inFlight[pending.id] = pending }
        if kind == "tail" { history.truncatedTail = true }
        if kind == "missingIdentity" { snapshot.processIdentities = [:] }
        let id = kind == "unknownEnvironment" ? EnvironmentID() : environment.id
        let result = inspector.status(for: id, snapshot: snapshot, journal: history, metadataUsable: kind != "metadata")
        #expect(calls.withLock { $0 } == 0)
        #expect(result.reconciledAt == nil)
        if kind == "pending" {
            #expect(result.vm == .uncertain(reason: .operationOutcomeUnknown))
            #expect(result.inFlightOperation == pending.id)
            #expect(result.readiness == .needsAttention(.operationOutcomeUnknown(pending.id)))
        } else {
            #expect(result.vm == .uncertain(reason: kind == "missingIdentity" ? .ownershipUnproven : .inspectionFailed))
        }
    }

    @Test func unselectedProviderAndNativeQueryNeverInventAbsence() throws {
        let result = RuntimeEnvironmentInspector().status(for: environment.id, snapshot: try snapshot(), journal: journal, metadataUsable: true)
        #expect(result.vm == .uncertain(reason: .inspectionFailed))
        let version = RuntimeVersionInfo(serviceVersion: "test", serviceBuild: "1", protocolVersion: .current, runtime: nil)
        guard case .readOnly(let inspect) = NativeRuntimeRequestHandler.queryPlan(.environmentStatus(environment.id), version: version, state: nil) else {
            Issue.record("Status must use bounded read-only dispatch"); return
        }
        #expect(inspect() == .status(RuntimeEnvironmentInspector.unavailable(environment.id)))
    }
}
