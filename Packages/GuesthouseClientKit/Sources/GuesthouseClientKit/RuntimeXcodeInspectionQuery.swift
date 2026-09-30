import GuesthouseCore

/// One read-only Xcode selection check (#26, MVP-PLAN.md §3), using the existing backend owner.
/// A candidate is not import authority. The GUI must fence superseded results and retain security scope.
public enum RuntimeXcodeInspectionQuery {
    public enum Failure: Error, Hashable, Sendable {
        case selection(XcodeSelectionFailure), runtime(GuesthouseError), connection(RuntimeSessionFailure), timedOut, canceled

        public var userMessage: String {
            switch self {
            case .selection(let error): error.userMessage
            case .runtime(let error): error.userMessage
            case .connection(let error): error.userMessage
            case .timedOut: "The runtime service did not answer the Xcode inspection within 30 seconds."
            case .canceled: "The Xcode inspection was canceled."
            }
        }
        public var recoveryMessage: String {
            switch self {
            case .selection(let error): error.recoveryActions.map(\.title).joined(separator: "; ")
            case .runtime(let error): error.recoveryMessage
            case .connection(let error): error.recoveryActions.map(\.title).joined(separator: "; ")
            case .timedOut: "Try this read-only check again. If it keeps timing out, quit and reopen Guesthouse."
            case .canceled: "You can run another read-only Xcode inspection when ready."
            }
        }
    }
    public typealias Outcome = Result<XcodeCandidate, Failure>

    @concurrent public static func run(selection: XcodeSelectionAccess) async -> Outcome {
        let deadline = ContinuousClock.now + .seconds(30)
        return await perform(selection: selection, connect: nil, deadline: { try await ContinuousClock().sleep(until: deadline) })
    }

    // Session/deadline injection is package-only, not caller-selected paths, policy or commands.
    static func perform(selection: XcodeSelectionAccess, connect: XPCRuntimeTransport.Connect?,
                        deadline: @escaping @Sendable () async throws -> Void) async -> Outcome {
        guard !Task.isCancelled else { return .failure(.canceled) }
        // As in RuntimeVersionQuery, disable the client's second timer. Await both structured
        // children and explicit close before another user-requested check can reuse the UI.
        let client = RuntimeClient(connect: connect, permitsOperations: false, deadline: nil, selection: selection)
        let stream = client.send(.inspectXcode(selection.handoff))
        await client.flush()
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    for try await event in stream {
                        switch event {
                        case .xcodeSelection(.candidate(let candidate)): return .success(candidate)
                        case .xcodeSelection(.rejected(let reason)): return .failure(.selection(reason))
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
