import GuesthouseCore

/// Advertised command surfaces from a complete bounded inspection, never readiness or
/// provider acceptance. No raw help text, VNC/Stop/GPU verdict or executable authority.
struct LumeProbeResult: Equatable, Sendable {
    let version: SemanticVersion
    let unattendedTahoeAdvertised: Bool
    let createRunAttachStorageAdvertised: Bool
    let detachedRunAdvertised: Bool
    let nativeAttachAdvertised: Bool
}

/// Fixed sequencing/aggregation only: the callback grants no launch, verification or
/// settlement authority. StateStore supplies its existing strict fixed launcher and actual
/// inspected completion to the lease-owning entry below.
enum LumeProbeSequence {
    static func run(in storage: RuntimeStorage, coordinator: LumeRuntimeCoordinator,
                    step: @escaping @Sendable (LumeLaunchIntent.Command) async throws -> LumeProbeResponse) async throws -> LumeProbeResult {
        try await coordinator.withExclusiveAccess(for: storage) { try await run(step: step) }
    }

    static func run(step: @Sendable (LumeLaunchIntent.Command) async throws -> LumeProbeResponse) async throws -> LumeProbeResult {
        func response(_ command: LumeLaunchIntent.Command) async throws -> LumeProbeResponse {
            try Task.checkCancellation()
            let value = try await step(command)
            try Task.checkCancellation() // Never advance or return aggregate success after cancellation.
            return value
        }
        guard case .version(let version) = try await response(.version) else {
            throw LumeProbeResponseFailure.invalidResponse
        }
        guard version == LumePin.version else { throw LumeProbeResponseFailure.versionMismatch }
        guard case .createHelp(let unattended, let createStorage) = try await response(.createHelp),
              case .detachedRunHelp(let detached, let runStorage) = try await response(.detachedRunHelp),
              case .attachHelp(let native, let attachStorage) = try await response(.attachHelp) else {
            throw LumeProbeResponseFailure.invalidResponse
        }
        return LumeProbeResult(version: version, unattendedTahoeAdvertised: unattended,
            createRunAttachStorageAdvertised: createStorage && runStorage && attachStorage,
            detachedRunAdvertised: detached, nativeAttachAdvertised: native)
    }
}
