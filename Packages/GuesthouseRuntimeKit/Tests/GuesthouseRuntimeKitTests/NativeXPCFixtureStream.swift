import Dispatch
import Synchronization

// Test-only closed progress evidence. No native error description or message payload
// is copied into a timeout, and independent sessions keep independent callback queues.
final class NativeXPCFixtureProgress: Sendable {
    enum Stage: Sendable { case connecting, accepting, bound, received, processed, reply, canceled }
    struct Snapshot: Sendable { let stage: Stage; let servicedQueues: Int }
    private let value = Mutex(Snapshot(stage: .connecting, servicedQueues: 0))
    func record(_ stage: Stage) {
        value.withLock { $0 = Snapshot(stage: stage, servicedQueues: $0.servicedQueues) }
    }
    func observe(_ queue: DispatchQueue, bit: Int) {
        queue.async { self.value.withLock { $0 = Snapshot(stage: $0.stage, servicedQueues: $0.servicedQueues | bit) } }
    }
    var snapshot: Snapshot { value.withLock { $0 } }
}

struct NativeXPCFixtureStream<Element: Sendable>: Sendable {
    let stream: AsyncThrowingStream<Element, any Error>
    let progress: NativeXPCFixtureProgress

    func next() async throws -> Element {
        try await withThrowingTaskGroup(of: Element.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                let value = try await iterator.next()
                // Cancellation legitimately ends the losing iterator. It is not another
                // failed #require or evidence that the native peer ended the stream.
                try Task.checkCancellation()
                guard let value else { throw NativeXPCFixtureFailure.streamEnded }
                return value
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw NativeXPCFixtureFailure.timeout(progress.snapshot)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw NativeXPCFixtureFailure.streamEnded }
            return result
        }
    }
}

enum NativeXPCFixtureFailure: Error {
    case timeout(NativeXPCFixtureProgress.Snapshot)
    case streamEnded
}
