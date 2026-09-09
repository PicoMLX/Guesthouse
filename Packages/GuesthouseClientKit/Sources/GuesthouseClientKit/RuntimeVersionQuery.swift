import GuesthouseCore

/// One user-requested, read-only check through the production RuntimeBackend owner.
/// Native callbacks only enqueue; explicit connection cleanup finishes before returning.
public enum RuntimeVersionQuery {
    public enum Failure: Error, Hashable, Sendable {
        case runtime(GuesthouseError), connection(RuntimeSessionFailure), timedOut, canceled

        public var userMessage: String {
            switch self {
            case .runtime(let error): error.userMessage
            case .connection(let error): error.userMessage
            case .timedOut: "The runtime service did not answer the connection check within 10 seconds."
            case .canceled: "The connection check was canceled."
            }
        }
        public var recoveryMessage: String {
            switch self {
            case .runtime(let error): error.recoveryMessage
            case .connection(let error): error.recoveryActions.map(\.title).joined(separator: "; ")
            case .timedOut: "Try this read-only check again. If it keeps timing out, quit and reopen Guesthouse."
            case .canceled: "You can run another read-only connection check when ready."
            }
        }
    }
    public typealias Outcome = Result<RuntimeVersionInfo, Failure>

    @concurrent public static func run() async -> Outcome {
        let deadline = ContinuousClock.now + .seconds(10)
        return await perform(connect: nil, deadline: { try await ContinuousClock().sleep(until: deadline) })
    }

    // Inject native-session creation/deadline only in package tests, never from GUI requests.
    static func perform(connect: XPCRuntimeTransport.Connect?,
                        deadline: @escaping @Sendable () async throws -> Void) async -> Outcome {
        guard !Task.isCancelled else { return .failure(.canceled) }
        // This structured group owns the query's ONLY deadline and always awaits close.
        // A second client timer could win with connectionLost instead of timedOut.
        let client = RuntimeClient(connect: connect, permitsOperations: false, deadline: nil)
        let stream = client.send(.runtimeVersion)
        await client.flush()
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    for try await event in stream { return result(.success(event)) }
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
        return outcome
    }

    private static func result(_ reply: Result<RuntimeEvent, RuntimeSessionFailure>) -> Outcome {
        switch reply {
        case .failure(let error): return .failure(.connection(error))
        case .success(.runtimeVersion(let info)) where info.protocolVersion == .current: return .success(info)
        case .success(.failed(_, let error)): return .failure(.runtime(error))
        case .success(.accepted(let id)), .success(.completed(let id)), .success(.progress(let id, _)):
            return .failure(.connection(.init(cause: .malformedResponse, operationID: id)))
        default: return .failure(.connection(.init(cause: .malformedResponse)))
        }
    }
}
