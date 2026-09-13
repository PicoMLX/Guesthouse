import Foundation
import GuesthouseCore
import Synchronization
import XPC

/// GUI-side native client migrated from #67/#68/#103 (#19/#112, MVP-PLAN.md §3).
/// Used by the GUI's read-only connection check with the embedded service's shared wire epoch.
/// All callbacks MUST only enqueue bounded, nonblocking work and must not reenter transport.
/// There is no replay, background reconnect, process execution or raw diagnostic output.
public final class XPCRuntimeTransport: Sendable {
    static let serviceName = "com.starlingprotocol.Guesthouse.Runtime"
    typealias Connect = @Sendable (
        @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void,
        @escaping @Sendable () -> Void
    ) throws -> any RuntimeClientSession
    private let registry: RuntimeSessionRegistry<any RuntimeClientSession>
    private let setup = Mutex(())
    private let connect: Connect

    public convenience init(incoming: @escaping @Sendable (RuntimeEvent) -> Void,
                            interrupted: @escaping @Sendable (RuntimeSessionFailure) -> Void) {
        self.init(incoming: incoming, interrupted: interrupted, connect: Self.connectToService)
    }

    init(incoming: @escaping @Sendable (RuntimeEvent) -> Void,
         interrupted: @escaping @Sendable (RuntimeSessionFailure) -> Void,
         connect: @escaping Connect) {
        registry = RuntimeSessionRegistry(incoming: incoming, interrupted: interrupted)
        self.connect = connect
    }

    deinit {
        retireCurrent()
    }

    /// Owner/drain only, never from a callback executing under the registry delivery lock.
    func retireCurrent() {
        if let lease = registry.current { Self.retire(lease.generation, in: registry) }
    }

    /// Only the read-only query is public until the streaming client/outcome routing migrates.
    public func queryRuntimeVersion(reply: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void) throws {
        try send(RuntimeRequestEnvelope(request: .runtimeVersion), reply: reply)
    }

    func send(_ envelope: RuntimeRequestEnvelope,
              reply: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void) throws {
        let bytes: Data
        do {
            try RequestValidator.validate(envelope)
            bytes = try JSONEncoder().encode(envelope)
            try RequestValidator.validateEncodedSize(bytes)
        } catch let error as RequestValidationError { throw error.guesthouseError }
        catch { throw GuesthouseError.invalidRequest(.malformed) }
        let lease = try activeSession()
        let mayMutate: Bool
        switch envelope.request {
        case .runtimeVersion, .hostPreflight, .environmentStatus: mayMutate = false
        case .startEnvironment, .stopEnvironment, .importXcode, .cancelOperation: mayMutate = true
        }
        // Retain the registry, not self: deinit can cancel pending work, while late callbacks
        // still preserve learned operation IDs. Native sessions capture the registry weakly.
        lease.session.send(bytes) { [registry] result in
            if case .failure(let failure) = result { Self.retire(lease.generation, in: registry, failure: failure) }
            registry.deliverReply(result, from: lease.generation) { delivered in
                reply(delivered.mapError { $0.contextualized(mayHaveMutated: mayMutate) })
            }
        }
    }

    private func activeSession() throws -> RuntimeSessionRegistry<any RuntimeClientSession>.Lease {
        // Setup is serialized separately: native callbacks/retirement never need this lock.
        try setup.withLock { _ in
            if let current = registry.current { return current }
            guard let generation = registry.reserve() else { throw RuntimeSessionFailure(cause: .connectionLost) }
            do {
                let candidate = try connect(
                    { [weak registry] result in
                        guard let registry else { return }
                        switch result {
                        case .success(let event): registry.deliverIncoming(event, from: generation)
                        case .failure(let failure): Self.retire(generation, in: registry, failure: failure)
                        }
                    },
                    { [weak registry] in
                        if let registry { Self.retire(generation, in: registry) }
                    }
                )
                guard registry.install(candidate, for: generation) else {
                    candidate.cancel() // Creator still owns this uninstalled candidate.
                    throw RuntimeSessionFailure(cause: .connectionLost)
                }
                try candidate.activate()
                guard registry.activated(generation), let lease = registry.current,
                      lease.generation === generation else { throw RuntimeSessionFailure(cause: .connectionLost) }
                return lease
            } catch {
                Self.retire(generation, in: registry)
                throw generation.retirementFailure ?? RuntimeSessionFailure(cause: .connectionLost)
            }
        }
    }

    private static func retire(_ generation: RuntimeSessionGeneration,
                               in registry: RuntimeSessionRegistry<any RuntimeClientSession>,
                               failure: RuntimeSessionFailure = .init(cause: .connectionLost)) {
        registry.retire(generation, failure: failure)?.cancel() // Outside delivery lock; sole cleanup owner.
    }

    private static func connectToService(
        incoming: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void,
        dropped: @escaping @Sendable () -> Void
    ) throws -> any RuntimeClientSession {
        let native = try XPCSession(
            xpcService: serviceName, options: .inactive,
            requirement: .isFromSameTeam(andMatchesSigningIdentifier: serviceName),
            incomingMessageHandler: { (message: XPCDictionary) -> XPCDictionary? in
                incoming(NativeRuntimeSession.decode(message)); return nil
            }, cancellationHandler: { _ in dropped() }
        )
        return NativeRuntimeSession(native)
    }
}
