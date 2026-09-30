import GuesthouseCore

/// Explicit metadata setup only. Reuses version-reply transport, but never read-only retry advice.
public enum RuntimeStorageSetup {
    public enum Failure: Error, Hashable, Sendable {
        case needsInspection(RuntimeSavedStateStatus?), unconfirmed
        public var userMessage: String {
            switch self {
            case .needsInspection(let status): status?.userMessage ?? "The runtime did not confirm storage setup."
            case .unconfirmed: "Guesthouse could not confirm whether storage setup finished."
            }
        }
        public var recoveryMessage: String {
            "Keep existing storage unchanged. Reopen Guesthouse and check the runtime connection to inspect the result before another setup attempt."
        }
    }
    public typealias Outcome = Result<RuntimeVersionInfo, Failure>

    @concurrent public static func run() async -> Outcome {
        let deadline = ContinuousClock.now + .seconds(10)
        return await perform(connect: nil, deadline: { try await ContinuousClock().sleep(until: deadline) })
    }

    static func perform(connect: XPCRuntimeTransport.Connect?,
                        deadline: @escaping @Sendable () async throws -> Void) async -> Outcome {
        switch await RuntimeVersionQuery.perform(request: .prepareStorage, connect: connect, deadline: deadline) {
        case .success(let info) where info.savedState == .loaded: .success(info)
        case .success(let info): .failure(.needsInspection(info.savedState))
        case .failure: .failure(.unconfirmed)
        }
    }
}
