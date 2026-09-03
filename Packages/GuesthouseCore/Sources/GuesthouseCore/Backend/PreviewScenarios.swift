import Foundation

/// Ready-made app states for SwiftUI previews and view-model tests. No I/O.
public struct PreviewScenario: Sendable {
    public let name: String
    /// What the state store would hold.
    public let snapshot: EnvironmentsSnapshot
    /// A fake backend scripted to match.
    public let backend: FakeRuntimeBackend

    public init(name: String, snapshot: EnvironmentsSnapshot, backend: FakeRuntimeBackend) {
        self.name = name
        self.snapshot = snapshot
        self.backend = backend
    }
}

public enum PreviewScenarios {
    public static let all: [@Sendable () async -> PreviewScenario] = [
        { await freshMac() }, { await oneRunningEnvironment() }, { await environmentNeedingRepair() },
        { await bothSlotsFull() }, { await operationInProgress() },
    ]

    /// First launch: nothing exists yet.
    public static func freshMac() async -> PreviewScenario {
        PreviewScenario(name: "Fresh Mac", snapshot: .empty, backend: FakeRuntimeBackend())
    }

    /// One environment, running and ready, with known tool versions.
    public static func oneRunningEnvironment() async -> PreviewScenario {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: date)
        let snapshot = try! snapshot(for: [environment], provisioning: [environment.id: ProvisioningState(stage: .ready, status: .completed(Checkpoint(stage: .ready, reachedAt: date)))])
        let backend = FakeRuntimeBackend()
        await backend.setStatus(EnvironmentStatus(
            environmentID: environment.id, vm: .running, readiness: .ready,
            observed: ObservedTuple(hostMacOSVersion: SemanticVersion("26.5.2"), tartVersion: "2.36.0", guestMacOSBuild: "25F84", xcodeBuild: "17F113"),
            reconciledAt: date
        ))
        await backend.script("stopEnvironment", .succeed(phases: [ProgressPhase(kind: .stoppingVM)]))
        return PreviewScenario(name: "One running environment", snapshot: snapshot, backend: backend)
    }

    /// A stopped environment whose SSH identity changed; Start is refused until repaired.
    public static func environmentNeedingRepair() async -> PreviewScenario {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: date)
        let snapshot = try! snapshot(for: [environment], provisioning: [environment.id: ProvisioningState(stage: .sshPaired, status: .recoverableFailure(.hostKeyChanged(environment.id)))])
        let backend = FakeRuntimeBackend()
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .needsAttention(.hostKeyChanged(environment.id)), reconciledAt: date))
        await backend.script("startEnvironment", .fail(error: .hostKeyChanged(environment.id)))
        return PreviewScenario(name: "Environment needing repair", snapshot: snapshot, backend: backend)
    }

    /// Two environments, one preserved after a failed repair, so no slot is free.
    public static func bothSlotsFull() async -> PreviewScenario {
        let active = DevelopmentEnvironment(name: "Dev Mac", createdAt: date)
        let preserved = DevelopmentEnvironment(name: "Old Dev Mac", createdAt: date.addingTimeInterval(-86_400 * 30))
        var snapshot = try! snapshot(for: [active, preserved], provisioning: [
            active.id: ProvisioningState(stage: .ready, status: .completed(Checkpoint(stage: .ready, reachedAt: date))),
            preserved.id: ProvisioningState(stage: .guestSecured, status: .recoverableFailure(.guestNotReachable(preserved.id))),
        ])
        try! snapshot.slots.markPreserved(preserved.id)
        let backend = FakeRuntimeBackend()
        await backend.setStatus(EnvironmentStatus(environmentID: active.id, vm: .stopped, readiness: .ready, reconciledAt: date))
        await backend.setStatus(EnvironmentStatus(environmentID: preserved.id, vm: .stopped, readiness: .needsAttention(.guestNotReachable(preserved.id)), reconciledAt: date))
        return PreviewScenario(name: "Both slots full", snapshot: snapshot, backend: backend)
    }

    /// A start operation that keeps reporting progress, for progress UI.
    public static func operationInProgress() async -> PreviewScenario {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: date)
        let snapshot = try! snapshot(for: [environment], provisioning: [environment.id: ProvisioningState(stage: .ready, status: .completed(Checkpoint(stage: .ready, reachedAt: date)))])
        let backend = FakeRuntimeBackend(delay: .milliseconds(800))
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, reconciledAt: date))
        await backend.script("startEnvironment", .succeed(phases: [
            ProgressPhase(kind: .verifyingRuntime), ProgressPhase(kind: .startingVM), ProgressPhase(kind: .waitingForNetwork, fraction: 0.3), ProgressPhase(kind: .waitingForNetwork, fraction: 0.9),
        ], status: EnvironmentStatus(environmentID: environment.id, vm: .running, readiness: .ready, reconciledAt: date)))
        return PreviewScenario(name: "Operation in progress", snapshot: snapshot, backend: backend)
    }

    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    private static func snapshot(for environments: [DevelopmentEnvironment], provisioning: [EnvironmentID: ProvisioningState]) throws -> EnvironmentsSnapshot {
        var slots = VMSlotInventory()
        for environment in environments {
            try slots.reserve(environment.id)
        }
        return EnvironmentsSnapshot(environments: environments, slots: slots, provisioning: provisioning)
    }
}
