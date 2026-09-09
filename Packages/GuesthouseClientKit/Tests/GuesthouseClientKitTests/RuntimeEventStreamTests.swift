import Dispatch
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseClientKit

@Suite(.timeLimit(.minutes(1))) struct RuntimeEventStreamTests {
    static let id = OperationID()
    static let info = RuntimeVersionInfo(serviceVersion: "1", serviceBuild: "1")
    static var progress: RuntimeEvent { .progress(id, .init(kind: .copying)) }
    static let traffic: [RuntimeEvent] = [
        progress, .diagnostic(.init(operation: .startEnvironment, outcome: .started, operationID: id.uuid)),
        .status(.init(environmentID: EnvironmentID(), vm: .running, readiness: .checking, inFlightOperation: id)),
        .status(.init(environmentID: EnvironmentID(), vm: .running, readiness: .checking)),
    ]

    @Test(arguments: traffic, [RuntimeEvent.completed(id), .failed(id, .runtimeMissing)])
    func floodRetainsAcceptanceAndTerminal(traffic: RuntimeEvent, terminal: RuntimeEvent) async throws {
        let notices = Mutex<[RuntimeEventStream.Termination]>([])
        let pair = RuntimeEventStream.make(capacity: 4, mayHaveMutated: true) { reason in notices.withLock { $0.append(reason) } }
        pair.producer.reply(.accepted(Self.id))
        for _ in 0..<10_000 { pair.producer.push(traffic) }
        #expect(pair.producer.bufferedCount == 3)
        #expect(pair.producer.droppedCount == 9_998)
        pair.producer.push(terminal)
        #expect(pair.producer.bufferedCount == 4)
        pair.producer.push(.completed(Self.id)) // Neither duplicate terminal nor late failure wins.
        pair.producer.interrupt(.init(cause: .connectionLost))
        let values = try await collect(pair.stream)
        #expect(values == [.accepted(Self.id), traffic, traffic, terminal])
        #expect(notices.withLock { $0 } == [.finished])
        #expect(pair.producer.bufferedCount == 0)
    }

    @Test func aReaderThatCatchesUpResumesTrafficImmediately() async throws {
        let pair = RuntimeEventStream.make(capacity: 3, mayHaveMutated: true) { _ in }
        pair.producer.reply(.accepted(Self.id))
        for _ in 0..<100 { pair.producer.push(Self.progress) }
        var iterator = pair.stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted(Self.id))
        #expect(try await iterator.next() == Self.progress)
        #expect(pair.producer.bufferedCount == 0)
        for _ in 0..<100 {
            pair.producer.push(Self.progress)
            #expect(try await iterator.next() == Self.progress)
        }
        pair.producer.push(.completed(Self.id))
        #expect(try await iterator.next() == .completed(Self.id))
        #expect(try await iterator.next() == nil)
    }

    @Test(arguments: [Int.min, 2, 64, 1_024, Int.max])
    func capacitiesAreClampedAndAlwaysReserveATerminalSlot(requested: Int) async throws {
        let pair = RuntimeEventStream.make(capacity: requested, mayHaveMutated: true) { _ in }
        let capacity = min(max(requested, 2), 1_024)
        pair.producer.reply(.accepted(Self.id))
        for _ in 0..<2_000 { pair.producer.push(Self.progress) }
        pair.producer.push(.completed(Self.id))
        #expect(pair.producer.bufferedCount == capacity)
        #expect(try await collect(pair.stream).count == capacity)
    }

    @Test(arguments: [RuntimeEvent.runtimeVersion(info),
                       .status(.init(environmentID: EnvironmentID(), vm: .stopped, readiness: .checking)),
                       .completed(id), .failed(id, .unauthorizedCaller)])
    func queryReplyFinishesOnce(event: RuntimeEvent) async throws {
        let pair = RuntimeEventStream.make(mayHaveMutated: false) { _ in }
        pair.producer.reply(event)
        pair.producer.reply(.accepted(Self.id))
        #expect(try await collect(pair.stream) == [event])
    }

    @Test(arguments: [false, true])
    func interruptionsRetainAcceptedAndPreacceptUncertainty(accepted: Bool) async throws {
        let pair = RuntimeEventStream.make(mayHaveMutated: true) { _ in }
        if accepted { pair.producer.reply(.accepted(Self.id)) }
        pair.producer.interrupt(.init(cause: .protocolMismatch(service: 11)))
        let expected = RuntimeSessionFailure(cause: .protocolMismatch(service: 11),
                                            operationID: accepted ? Self.id : nil, mayHaveMutated: true)
        var iterator = pair.stream.makeAsyncIterator()
        if accepted { #expect(try await iterator.next() == .accepted(Self.id)) }
        await #expect(throws: expected) { try await iterator.next() }
        #expect(!expected.recoveryActions.contains(.retry))
    }

    @Test func misroutedTrafficAndPrematurePushesAreNotDelivered() async throws {
        let pair = RuntimeEventStream.make(mayHaveMutated: true) { _ in }
        let other = OperationID()
        pair.producer.push(Self.progress) // Pending traffic is the router's separate responsibility.
        pair.producer.reply(.accepted(Self.id))
        for event in [RuntimeEvent.progress(other, .init(kind: .copying)),
                      .diagnostic(.init(operation: .startEnvironment, outcome: .started, operationID: other.uuid)),
                      .status(.init(environmentID: EnvironmentID(), vm: .running, readiness: .checking, inFlightOperation: other)),
                      .completed(other), .failed(other, .runtimeMissing)] { pair.producer.push(event) }
        pair.producer.push(.completed(Self.id))
        #expect(try await collect(pair.stream) == [.accepted(Self.id), .completed(Self.id)])
    }

    @Test(arguments: [false, true])
    func invalidControlEndsWithTypedUnknownOutcome(duplicateReply: Bool) async throws {
        let pair = RuntimeEventStream.make(mayHaveMutated: true) { _ in }
        pair.producer.reply(.accepted(Self.id))
        if duplicateReply { pair.producer.reply(.accepted(OperationID())) }
        else { pair.producer.push(.runtimeVersion(Self.info)) }
        var iterator = pair.stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted(Self.id))
        await #expect(throws: RuntimeSessionFailure(cause: .malformedResponse, operationID: Self.id, mayHaveMutated: true)) {
            try await iterator.next()
        }
    }

    @Test func droppingAnUnreadStreamNotifiesAbandonmentOnce() {
        let notices = Mutex<[RuntimeEventStream.Termination]>([])
        var stream: AsyncThrowingStream<RuntimeEvent, any Error>?
        let producer: RuntimeEventStream
        (producer, stream) = RuntimeEventStream.make(mayHaveMutated: true) { reason in notices.withLock { $0.append(reason) } }
        withExtendedLifetime(stream) {}
        stream = nil
        producer.reply(.accepted(Self.id))
        #expect(notices.withLock { $0 } == [.abandoned])
        #expect(producer.bufferedCount == 0)
    }

    @Test func canceledBeforeFirstReadStillNotifiesTheOwner() async throws {
        let notices = Mutex<[RuntimeEventStream.Termination]>([])
        let pair = RuntimeEventStream.make(mayHaveMutated: true) { reason in notices.withLock { $0.append(reason) } }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            var iterator = pair.stream.makeAsyncIterator()
            return try await iterator.next()
        }
        // The SDK can end an already-canceled unfolding iterator before invoking next().
        // No successful event is allowed, and cleanup must occur even while stream is retained.
        do { #expect(try await task.value == nil) }
        catch let error as GuesthouseError { #expect(error == .canceled) }
        #expect(notices.withLock { $0 } == [.abandoned])
        withExtendedLifetime(pair.stream) {}
    }

    @Test func sdkCancellationReleasesTheSkippedProducerWhileStreamIsRetained() async throws {
        let calls = Mutex(0), releases = Mutex(0)
        let stream: AsyncThrowingStream<Int, any Error>
        do {
            let capture = CancellationCapture { releases.withLock { $0 += 1 } }
            stream = AsyncThrowingStream(unfolding: {
                calls.withLock { $0 += 1 }
                return withExtendedLifetime(capture) { 1 }
            })
        }
        #expect(releases.withLock { $0 } == 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        #expect(try await task.value == nil)
        #expect(calls.withLock { $0 } == 0)
        #expect(releases.withLock { $0 } == 1)
        withExtendedLifetime(stream) {}
    }

    @Test func concurrentProducersDoNotOverfillOrFinishTwice() async throws {
        let notices = Mutex<[RuntimeEventStream.Termination]>([])
        let pair = RuntimeEventStream.make(capacity: 8, mayHaveMutated: true) { reason in notices.withLock { $0.append(reason) } }
        pair.producer.reply(.accepted(Self.id))
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index % 7 == 0 { pair.producer.push(.completed(Self.id)) }
            else { pair.producer.push(Self.progress) }
        }
        #expect(pair.producer.bufferedCount <= 8)
        let values = try await collect(pair.stream)
        #expect(values.first == .accepted(Self.id))
        #expect(values.last == .completed(Self.id))
        #expect(values.filter { $0 == .completed(Self.id) }.count == 1)
        #expect(notices.withLock { $0 } == [.finished])
    }

    @Test func lateAcceptanceIdentitySurvivesAPreacceptTransportFailure() async {
        let pair = RuntimeEventStream.make(mayHaveMutated: false) { _ in }
        let error = RuntimeSessionFailure(cause: .malformedResponse, operationID: Self.id)
        pair.producer.interrupt(error)
        await #expect(throws: error) { try await collect(pair.stream) }
        #expect(!error.recoveryActions.contains(.retry))
    }

    @Test(arguments: [false, true], [false, true])
    func lateInterruptionEnrichesOnlyUnreadFailure(accepted: Bool, observed: Bool) async throws {
        for cause in [RuntimeSessionFailure.Cause.connectionLost, .protocolMismatch(service: 11)] {
            let notices = Mutex<[RuntimeEventStream.Termination]>([])
            let pair = RuntimeEventStream.make(mayHaveMutated: true) { reason in notices.withLock { $0.append(reason) } }
            if accepted { pair.producer.reply(.accepted(Self.id)) }
            pair.producer.interrupt(.init(cause: cause))
            var iterator = pair.stream.makeAsyncIterator()
            if accepted { #expect(try await iterator.next() == .accepted(Self.id)) }
            let first = RuntimeSessionFailure(cause: cause,
                                              operationID: accepted ? Self.id : nil, mayHaveMutated: true)
            if observed { await #expect(throws: first) { try await iterator.next() } }
            pair.producer.interrupt(.init(cause: .protocolMismatch(service: 11), operationID: Self.id))
            pair.producer.interrupt(.init(cause: .oversizedResponse, operationID: OperationID()))
            let expected = observed ? first : RuntimeSessionFailure(
                cause: .protocolMismatch(service: 11), operationID: Self.id, mayHaveMutated: true)
            await #expect(throws: expected) { try await iterator.next() }
            #expect(!expected.recoveryActions.contains(.retry))
            #expect(notices.withLock { $0 } == [.finished])
        }
    }

    @Test func localRejectionDoesNotInventAnOperationOrEraseAnAcceptedOne() async throws {
        let rejected = RuntimeEventStream.make(mayHaveMutated: true) { _ in }
        rejected.producer.rejectBeforeSend(.invalidRequest(.malformed))
        await #expect(throws: GuesthouseError.invalidRequest(.malformed)) { try await collect(rejected.stream) }
        #expect(rejected.producer.bufferedCount == 0)
        let accepted = RuntimeEventStream.make(mayHaveMutated: true) { _ in }
        accepted.producer.reply(.accepted(Self.id))
        accepted.producer.rejectBeforeSend(.invalidRequest(.malformed))
        var iterator = accepted.stream.makeAsyncIterator()
        #expect(try await iterator.next() == .accepted(Self.id))
        await #expect(throws: RuntimeSessionFailure(cause: .malformedResponse, operationID: Self.id, mayHaveMutated: true)) {
            try await iterator.next()
        }
    }

    @Test(arguments: [progress, traffic[1]], [false, true])
    func invalidInitialRepliesDoNotPretendToComplete(event: RuntimeEvent, mutating: Bool) async {
        let pair = RuntimeEventStream.make(mayHaveMutated: mutating) { _ in }
        pair.producer.reply(event)
        await #expect(throws: RuntimeSessionFailure(cause: .malformedResponse, mayHaveMutated: mutating)) {
            try await collect(pair.stream)
        }
    }

    @Test func completionReleasesTheOwnersCallbackBeforeTheStreamIsReleased() {
        var retainedStream: AsyncThrowingStream<RuntimeEvent, any Error>?
        weak var scopedOwner: Owner?
        do {
            let owner = Owner()
            scopedOwner = owner
            let pair = makeCapturing(owner)
            retainedStream = pair.stream
            pair.producer.reply(.runtimeVersion(Self.info))
        }
        #expect(scopedOwner == nil)
        withExtendedLifetime(retainedStream) {}
    }

    @Test func cancellationWhileReadingReleasesTheBufferAndNotifiesOnce() async throws {
        let notices = Mutex<[RuntimeEventStream.Termination]>([])
        let pair = RuntimeEventStream.make(mayHaveMutated: true) { reason in notices.withLock { $0.append(reason) } }
        let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pair.producer.reply(.accepted(Self.id))
        let task = Task {
            var iterator = pair.stream.makeAsyncIterator()
            #expect(try await iterator.next() == .accepted(Self.id))
            signal.yield(()); signal.finish()
            return try await iterator.next()
        }
        for await _ in started { break }
        task.cancel()
        // Cancellation can win before the unfolding closure starts its second read.
        do { #expect(try await task.value == nil) }
        catch let error as GuesthouseError { #expect(error == .canceled) }
        pair.producer.push(.completed(Self.id))
        #expect(pair.producer.bufferedCount == 0)
        #expect(notices.withLock { $0 } == [.abandoned])
    }

    @Test func terminationCallbackCanReadProducerStateWithoutLockReentry() {
        let holder = Mutex<RuntimeEventStream?>(nil)
        let observed = Mutex<[Int]>([])
        let pair = RuntimeEventStream.make(mayHaveMutated: false) { _ in
            let count = holder.withLock { $0 }?.bufferedCount ?? -1
            observed.withLock { $0.append(count) }
        }
        holder.withLock { $0 = pair.producer }
        defer { holder.withLock { $0 = nil } }
        pair.producer.reply(.runtimeVersion(Self.info))
        #expect(observed.withLock { $0 } == [1])
        withExtendedLifetime(pair.stream) {}
    }
}

private final class Owner: Sendable {}
private final class CancellationCapture: Sendable {
    let released: @Sendable () -> Void
    init(_ released: @escaping @Sendable () -> Void) { self.released = released }
    deinit { released() }
}
private func makeCapturing(_ owner: Owner)
    -> (producer: RuntimeEventStream, stream: AsyncThrowingStream<RuntimeEvent, any Error>) {
    RuntimeEventStream.make(mayHaveMutated: false) { _ in withExtendedLifetime(owner) {} }
}
private func collect(_ stream: AsyncThrowingStream<RuntimeEvent, any Error>) async throws -> [RuntimeEvent] {
    var result: [RuntimeEvent] = []
    for try await event in stream { result.append(event) }
    return result
}
