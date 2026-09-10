import GuesthouseCore

/// One read-only host check (#12, MVP-PLAN.md §§2–3), using the existing backend owner.
/// A report is not mutation admission. The GUI must still fence superseded check results.
public enum RuntimeHostPreflightQuery {
    public enum Failure: Error, Hashable, Sendable {
        case runtime(GuesthouseError), connection(RuntimeSessionFailure), timedOut, canceled

        public var userMessage: String {
            switch self {
            case .runtime(let error): error.userMessage
            case .connection(let error): error.userMessage
            case .timedOut: "The runtime service did not answer the host check within 10 seconds."
            case .canceled: "The host check was canceled."
            }
        }
        public var recoveryMessage: String {
            switch self {
            case .runtime(let error): error.recoveryMessage
            case .connection(let error): error.recoveryActions.map(\.title).joined(separator: "; ")
            case .timedOut: "Try this read-only check again. If it keeps timing out, quit and reopen Guesthouse."
            case .canceled: "You can run another read-only host check when ready."
            }
        }
    }
    public typealias Outcome = Result<PreflightReport, Failure>

    @concurrent public static func run() async -> Outcome {
        let deadline = ContinuousClock.now + .seconds(10)
        return await perform(connect: nil, deadline: { try await ContinuousClock().sleep(until: deadline) })
    }

    // Session/deadline injection is package-only, not caller-selected paths, policy or commands.
    static func perform(connect: XPCRuntimeTransport.Connect?,
                        deadline: @escaping @Sendable () async throws -> Void) async -> Outcome {
        guard !Task.isCancelled else { return .failure(.canceled) }
        // As in RuntimeVersionQuery, disable the client's second timer. Await both structured
        // children and explicit close before another user-requested check can reuse the UI.
        let client = RuntimeClient(connect: connect, permitsOperations: false, deadline: nil)
        let stream = client.send(.hostPreflight)
        await client.flush()
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    for try await event in stream {
                        switch event {
                        case .hostPreflight(let report) where report.isComplete: return .success(report)
                        case .failed(_, let error): return .failure(.runtime(error))
                        default: return .failure(.connection(.init(cause: .malformedResponse, operationID: event.routingID)))
                        }
                    }
                    return .failure(.canceled)
                } catch let failure as RuntimeSessionFailure { return .failure(.connection(failure)) }
                catch GuesthouseError.canceled { return .failure(.canceled) }
                catch GuesthouseError.runtimeIncompatible { return .failure(.connection(.init(cause: .connectionLost))) }
                catch let error as GuesthouseError { return .failure(.runtime(error)) }
                catch { return .failure(.connection(.init(cause: .connectionLost))) }
            }
            group.addTask {
                do { try await deadline(); return .failure(.timedOut) }
                catch { return .failure(.canceled) }
            }
            defer { group.cancelAll() }
            let value = await group.next() ?? .failure(.canceled)
            return Task.isCancelled ? .failure(.canceled) : value
        }
        await client.close()
        return Task.isCancelled ? .failure(.canceled) : outcome
    }
}
