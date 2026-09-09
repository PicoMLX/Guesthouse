import GuesthouseCore

/// Identity is retained until its owning reply arrives, even if the consumer has left.
final class RuntimeRequestKey: Hashable, Sendable {
    static func == (lhs: RuntimeRequestKey, rhs: RuntimeRequestKey) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Serial-owner routing state migrated from #67/#103 (MVP-PLAN.md §3). No native calls.
/// The owner must feed validated callbacks through ONE bounded ordered inbox, execute effects
/// outside native callback locks, and process retirement before replacement-session traffic.
/// This is not the inbox, transport lifecycle or public RuntimeBackend implementation.
struct RuntimeEventRouter: Sendable {
    enum Admission: Equatable, Sendable { case admitted, full, retiring, rotationRequired }
    enum Effect: Equatable, Sendable {
        case cancel(OperationID), retireConnection
        /// The owner retains bounded reconciliation state even if the stream already ended.
        case unknownOutcome(RuntimeSessionFailure)
    }
    private struct Request: Sendable {
        let request: RuntimeRequest
        let producer: RuntimeEventStream
        var operation: OperationID?
        var awaiting = true
        var abandoned = false
        var invalidated: RuntimeSessionFailure.Cause?
    }
    static let requestLimit = 64
    static let lifetimeLimit = 1_024
    static let pendingIDLimit = 64
    static let pendingEventLimit = 16
    private var requests: [RuntimeRequestKey: Request] = [:]
    private var operations: [OperationID: RuntimeRequestKey] = [:]
    private var pending: [OperationID: [RuntimeEvent]] = [:]
    private var retired: Set<OperationID> = []
    private var admitted = 0
    private var requiresRetirement = false
    var requestCount: Int { requests.count }
    var pendingIDCount: Int { pending.count }
    var retiredCount: Int { retired.count }
    var isIdle: Bool { requests.isEmpty }

    /// The owner validates requests, then calls in send order BEFORE native send. On refusal
    /// it still owns the producer and must reject the unsent request. Planned budget rotation
    /// waits for idle; fault retirement is immediate. Neither permits replaying a sent mutation.
    mutating func register(_ key: RuntimeRequestKey, request: RuntimeRequest,
                           producer: RuntimeEventStream) -> Admission {
        guard !requiresRetirement else { return .retiring }
        guard admitted < Self.lifetimeLimit else { return .rotationRequired }
        guard requests.count < Self.requestLimit, requests[key] == nil else { return .full }
        requests[key] = Request(request: request, producer: producer)
        admitted += 1 // Bounds retired IDs for the whole connection, not only active requests.
        return .admitted
    }

    /// Only a verified pre-send local rejection, never an ambiguous native failure.
    mutating func rejected(_ key: RuntimeRequestKey, error: GuesthouseError) -> [Effect] {
        guard let entry = requests[key] else { return [] }
        guard entry.awaiting else { return fault(.malformedResponse) }
        requests.removeValue(forKey: key)
        entry.producer.rejectBeforeSend(error)
        discardUnjustifiedPending()
        return []
    }

    mutating func reply(_ result: Result<RuntimeEvent, RuntimeSessionFailure>,
                        to key: RuntimeRequestKey) -> [Effect] {
        guard var entry = requests[key] else { return [] }
        guard entry.awaiting else { return fault(.malformedResponse) }
        requests.removeValue(forKey: key)
        defer { discardUnjustifiedPending() }
        switch result {
        case .failure(let failure):
            return fail(entry, with: failure)
        case .success(let event):
            if let cause = entry.invalidated {
                // The requested retirement, not a late acceptance, owns cleanup.
                return fail(entry, with: .init(cause: cause, operationID: event.routingID))
            }
            guard entry.request.acceptsReply(event) else {
                let cause: RuntimeSessionFailure.Cause
                if case .runtimeVersion(let info) = event, info.protocolVersion != .current {
                    cause = .protocolMismatch(service: info.protocolVersion.rawValue)
                } else { cause = .malformedResponse }
                return fail(entry, with: .init(cause: cause, operationID: event.routingID)) + fault(cause)
            }
            guard case .accepted(let id) = event else { entry.producer.reply(event); return [] }
            guard operations[id] == nil, !retired.contains(id) else {
                return fail(entry, with: .init(cause: .malformedResponse, operationID: id)) + fault(.malformedResponse)
            }
            if entry.abandoned {
                pending.removeValue(forKey: id); retired.insert(id)
                return [.cancel(id)] // A live acceptance, not a replay of the original request.
            }
            entry.awaiting = false; entry.operation = id
            requests[key] = entry; operations[id] = key
            entry.producer.reply(event)
            for buffered in pending.removeValue(forKey: id) ?? [] { _ = route(buffered) }
            return []
        }
    }

    /// End callbacks enqueue this message; they must not reenter this mutable state directly.
    mutating func consumerEnded(_ key: RuntimeRequestKey, reason: RuntimeEventStream.Termination) -> [Effect] {
        guard reason == .abandoned, var entry = requests[key] else { return [] }
        guard let id = entry.operation else {
            entry.abandoned = true; requests[key] = entry; return []
        }
        remove(key, operation: id)
        return [.cancel(id)]
    }

    mutating func incoming(_ event: RuntimeEvent) -> [Effect] {
        guard !requiresRetirement else { return [] }
        switch event {
        case .accepted, .runtimeVersion: return fault(.malformedResponse)
        case .status(let status) where status.inFlightOperation == nil:
            for entry in requests.values where entry.operation != nil && entry.request.environment == status.environmentID {
                entry.producer.push(event)
            }
            return []
        default: return route(event)
        }
    }

    /// The registry fences stale pushes before this ordered notification. Pending owning
    /// replies remain: they carry late IDs/causes, and some may belong to a new generation
    /// whose send was queued before this notification. Never fail them indiscriminately.
    mutating func interrupted(_ failure: RuntimeSessionFailure) -> [Effect] {
        var effects: [Effect] = []
        for key in operations.values {
            // A generation-wide signal carries only cause, never another request's identity.
            if let entry = requests.removeValue(forKey: key) { effects += fail(entry, with: .init(cause: failure.cause)) }
        }
        operations.removeAll(); pending.removeAll(); retired.removeAll()
        admitted = requests.count; requiresRetirement = false
        return effects
    }

    private mutating func route(_ event: RuntimeEvent) -> [Effect] {
        guard let id = event.routingID else { return [] }
        if let key = operations[id], let entry = requests[key] {
            guard event.matchesEnvironment(entry.request.environment) else { return [] }
            if event.isTerminal { remove(key, operation: id) }
            entry.producer.push(event)
            return []
        }
        guard !retired.contains(id), requests.values.contains(where: {
            $0.awaiting && $0.invalidated == nil && $0.request.acceptsOperation && event.matchesEnvironment($0.request.environment)
        }) else { return [] }
        if pending[id] == nil, pending.count == Self.pendingIDLimit {
            return fault(.oversizedResponse) // Never silently lose a legitimate terminal/ID.
        }
        var events = pending[id] ?? []
        guard events.last?.isTerminal != true else { return [] }
        if event.isTerminal { events.append(event) }
        else if events.count < Self.pendingEventLimit - 1 { events.append(event) }
        pending[id] = events // One terminal slot is always free; duplicate terminals are dropped.
        return []
    }

    private mutating func remove(_ key: RuntimeRequestKey, operation: OperationID) {
        requests.removeValue(forKey: key); operations.removeValue(forKey: operation)
        pending.removeValue(forKey: operation); retired.insert(operation)
    }
    private mutating func discardUnjustifiedPending() {
        if !requests.values.contains(where: { $0.awaiting && $0.invalidated == nil && $0.request.acceptsOperation }) { pending.removeAll() }
    }
    private func fail(_ entry: Request, with failure: RuntimeSessionFailure) -> [Effect] {
        let scoped = failure.contextualized(operationID: entry.operation, mayHaveMutated: entry.request.mayMutate)
        entry.producer.interrupt(scoped)
        return scoped.outcomeUnknown ? [.unknownOutcome(scoped)] : []
    }
    private mutating func fault(_ cause: RuntimeSessionFailure.Cause) -> [Effect] {
        guard !requiresRetirement else { return [] }
        requiresRetirement = true; pending.removeAll()
        var effects: [Effect] = [.retireConnection]
        for key in Array(requests.keys) {
            guard var entry = requests[key] else { continue }
            if let id = entry.operation { remove(key, operation: id) }
            else { entry.invalidated = cause; requests[key] = entry }
            effects += fail(entry, with: .init(cause: cause))
        }
        return effects
    }
}

private extension RuntimeRequest {
    var mayMutate: Bool {
        switch self { case .runtimeVersion, .environmentStatus: false; default: true }
    }
    var environment: EnvironmentID? {
        switch self {
        case .environmentStatus(let id), .startEnvironment(let id, _), .stopEnvironment(let id, _), .importXcode(let id, _): id
        case .runtimeVersion, .cancelOperation: nil
        }
    }
    var acceptsOperation: Bool {
        switch self {
        case .startEnvironment, .stopEnvironment, .importXcode: true
        case .runtimeVersion, .environmentStatus, .cancelOperation: false
        }
    }
    func acceptsReply(_ event: RuntimeEvent) -> Bool {
        if case .failed = event { return true } // Correlated service rejection, not a live registration.
        switch (self, event) {
        case (.runtimeVersion, .runtimeVersion(let info)): return info.protocolVersion == .current
        case (.environmentStatus(let id), .status(let status)): return status.environmentID == id
        case (.cancelOperation, .completed): return true // Cancel-request acknowledgement, not proof its target stopped.
        case (_, .accepted): return acceptsOperation
        default: return false
        }
    }
}
private extension RuntimeEvent {
    var routingID: OperationID? {
        switch self {
        case .accepted(let id), .progress(let id, _), .completed(let id), .failed(let id, _): id
        case .diagnostic(let event): OperationID(uuid: event.operationID)
        case .status(let status): status.inFlightOperation
        case .runtimeVersion: nil
        }
    }
    var isTerminal: Bool {
        switch self { case .completed, .failed: true; default: false }
    }
    func matchesEnvironment(_ expected: EnvironmentID?) -> Bool {
        switch self {
        case .status(let status): status.environmentID == expected
        case .diagnostic(let event): event.environmentID == nil || event.environmentID == expected
        default: true
        }
    }
}
