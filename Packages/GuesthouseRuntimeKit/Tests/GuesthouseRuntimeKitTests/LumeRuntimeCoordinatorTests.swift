import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

private actor TestGate {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isOpen = false
    private var nextID: UInt64 = 0
    private var waiters: [Waiter] = []

    func wait() async throws {
        guard !isOpen else { return }
        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.continuation.resume() }
    }
}

private actor TwoPartyBarrier {
    private var arrivals = 0
    private let gate = TestGate()

    func arriveAndWait() async throws {
        arrivals += 1
        if arrivals == 2 { await gate.open() }
        try await gate.wait()
    }

    func release() async { await gate.open() }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct LumeRuntimeCoordinatorTests {
    private final class Fixture: Sendable {
        let base, root: URL
        let storage: RuntimeStorage
        init() throws {
            var template = Array("/private/tmp/guesthouse-lume-lease-XXXXXX".utf8CString)
            let name = try #require(mkdtemp(&template))
            base = URL(fileURLWithPath: String(cString: name))
            root = base.appending(path: "Guesthouse")
            storage = try RuntimeStorage(root: root)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
    }

    @Test func launchAndReplacementShareTheSameRootLease() async throws {
        let fixture = try Fixture(), storage = fixture.storage
        let releaseHolder = TestGate()
        let holderEntered = AsyncStream.makeStream(of: Void.self)
        var holderEvents = holderEntered.stream.makeAsyncIterator()
        let waiterQueued = AsyncStream.makeStream(of: Void.self)
        var waiterEvents = waiterQueued.stream.makeAsyncIterator()
        let waiterEntered = Mutex(false)
        let coordinator = LumeRuntimeCoordinator { waiterQueued.continuation.yield(()) }

        let holder = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                holderEntered.continuation.yield(())
                try await releaseHolder.wait()
            }
        }
        _ = await holderEvents.next()
        let waiter = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                waiterEntered.withLock { $0 = true }
            }
        }
        _ = await waiterEvents.next()

        #expect(!waiterEntered.withLock { $0 })
        await releaseHolder.open()
        _ = try await (holder.value, waiter.value)
        #expect(waiterEntered.withLock { $0 })
    }

    @Test func independentRuntimeRootsDoNotBlockEachOther() async throws {
        let firstFixture = try Fixture(), secondFixture = try Fixture()
        let firstStorage = firstFixture.storage, secondStorage = secondFixture.storage
        let barrier = TwoPartyBarrier()
        let coordinator = LumeRuntimeCoordinator()
        let watchdogFired = Mutex(false)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(2))
            watchdogFired.withLock { $0 = true }
            await barrier.release()
        }

        async let first: Void = coordinator.withExclusiveAccess(for: firstStorage) {
            try await barrier.arriveAndWait()
        }
        async let second: Void = coordinator.withExclusiveAccess(for: secondStorage) {
            try await barrier.arriveAndWait()
        }
        _ = try await (first, second)
        #expect(!watchdogFired.withLock { $0 }, "independent roots must enter concurrently")
        watchdog.cancel()
        _ = try? await watchdog.value
    }

    @Test func filesystemAliasesShareOneLease() async throws {
        let fixture = try Fixture()
        let aliasParent = fixture.base.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: fixture.base)
        let firstStorage = fixture.storage
        let secondStorage = try RuntimeStorage(existingRoot: aliasParent.appending(path: "Guesthouse"))
        #expect(try firstStorage.location(for: .runtime).path != secondStorage.location(for: .runtime).path)
        #expect(try firstStorage.coordinationIdentity() == secondStorage.coordinationIdentity())

        let releaseHolder = TestGate()
        let holderEntered = AsyncStream.makeStream(of: Void.self)
        var holderEvents = holderEntered.stream.makeAsyncIterator()
        let waiterQueued = AsyncStream.makeStream(of: Void.self)
        var waiterEvents = waiterQueued.stream.makeAsyncIterator()
        let waiterEntered = Mutex(false)
        let coordinator = LumeRuntimeCoordinator { waiterQueued.continuation.yield(()) }

        let holder = Task {
            try await coordinator.withExclusiveAccess(for: firstStorage) {
                holderEntered.continuation.yield(())
                try await releaseHolder.wait()
            }
        }
        _ = await holderEvents.next()
        let waiter = Task {
            try await coordinator.withExclusiveAccess(for: secondStorage) {
                waiterEntered.withLock { $0 = true }
            }
        }
        _ = await waiterEvents.next()

        #expect(!waiterEntered.withLock { $0 })
        await releaseHolder.open()
        _ = try await (holder.value, waiter.value)
    }

    @Test func canceledWaiterReturnsWhileTheHolderStillRuns() async throws {
        let fixture = try Fixture(), storage = fixture.storage
        let releaseHolder = TestGate()
        let holderEntered = AsyncStream.makeStream(of: Void.self)
        var holderEvents = holderEntered.stream.makeAsyncIterator()
        let waiterQueued = AsyncStream.makeStream(of: Void.self)
        var waiterEvents = waiterQueued.stream.makeAsyncIterator()
        let waiterEntered = Mutex(false)
        let coordinator = LumeRuntimeCoordinator { waiterQueued.continuation.yield(()) }
        let holder = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                holderEntered.continuation.yield(())
                try await releaseHolder.wait()
            }
        }
        _ = await holderEvents.next()

        let waiter = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                waiterEntered.withLock { $0 = true }
            }
        }
        _ = await waiterEvents.next()
        let fallbackFired = Mutex(false)
        let fallback = Task {
            try await Task.sleep(for: .seconds(2))
            fallbackFired.withLock { $0 = true }
            await releaseHolder.open()
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!fallbackFired.withLock { $0 }, "cancellation must not wait for the current holder")
        #expect(!waiterEntered.withLock { $0 })

        fallback.cancel()
        await releaseHolder.open()
        try await holder.value
        _ = try? await fallback.value
    }

    @Test func nestedLeaseFailsInsteadOfDeadlocking() async throws {
        let fixture = try Fixture(), storage = fixture.storage
        let coordinator = LumeRuntimeCoordinator()
        let failure = LumeRuntimeCoordinationError.nestedAcquisition
        #expect(failure.localizedDescription == failure.userMessage)
        #expect(failure.recoveryActions == [.cancel])

        await #expect(throws: failure) {
            try await coordinator.withExclusiveAccess(for: storage) {
                try await coordinator.withExclusiveAccess(for: storage) {}
            }
        }
        try await coordinator.withExclusiveAccess(for: storage) {}
    }

    @Test func oppositeRootOrderCannotDeadlock() async throws {
        let firstFixture = try Fixture(), secondFixture = try Fixture()
        let first = firstFixture.storage, second = secondFixture.storage
        let coordinator = LumeRuntimeCoordinator()

        await #expect(throws: LumeRuntimeCoordinationError.nestedAcquisition) {
            try await coordinator.withExclusiveAccess(for: first) {
                try await coordinator.withExclusiveAccess(for: second) {}
            }
        }
    }

    @Test func inheritedContextExpiresWithItsLease() async throws {
        let fixture = try Fixture(), storage = fixture.storage
        let coordinator = LumeRuntimeCoordinator()
        let mayEnter = TestGate()
        let child = try await coordinator.withExclusiveAccess(for: storage) {
            Task {
                try await mayEnter.wait()
                try await coordinator.withExclusiveAccess(for: storage) {}
            }
        }

        await mayEnter.open()
        try await child.value
    }

    @Test func queuedRootReplacementIsRefusedBeforeTheBodyRuns() async throws {
        let fixture = try Fixture(), storage = fixture.storage
        let entered = AsyncStream.makeStream(of: Void.self), queued = AsyncStream.makeStream(of: Void.self)
        var enteredEvents = entered.stream.makeAsyncIterator(), queuedEvents = queued.stream.makeAsyncIterator()
        let release = TestGate(), didRun = Mutex(false)
        let coordinator = LumeRuntimeCoordinator { queued.continuation.yield(()) }
        let holder = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                entered.continuation.yield(())
                try await release.wait()
            }
        }
        _ = await enteredEvents.next()
        let waiter = Task {
            try await coordinator.withExclusiveAccess(for: storage) { didRun.withLock { $0 = true } }
        }
        _ = await queuedEvents.next()
        // Benign isolated namespace change; no provider code or production layout is touched.
        let preserved = fixture.base.appending(path: "preserved")
        try FileManager.default.moveItem(at: fixture.root, to: preserved)
        _ = try RuntimeStorage(root: fixture.root)
        await release.open()
        try await holder.value
        await #expect(throws: StorageFailure.unsafeStructure) { try await waiter.value }
        #expect(!didRun.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: preserved.appending(path: "vms").path))
        try await coordinator.withExclusiveAccess(for: storage) {} // New admission gets the new key.
    }

    @Test func failureAndCancellationBalanceTheLease() async throws {
        let fixture = try Fixture(), storage = fixture.storage
        let coordinator = LumeRuntimeCoordinator()
        enum Failure: Error { case expected }
        await #expect(throws: Failure.expected) {
            try await coordinator.withExclusiveAccess(for: storage) { throw Failure.expected }
        }
        let entered = AsyncStream.makeStream(of: Void.self)
        var events = entered.stream.makeAsyncIterator()
        let gate = TestGate()
        let canceled = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                entered.continuation.yield(())
                try await gate.wait()
            }
        }
        _ = await events.next()
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        try await coordinator.withExclusiveAccess(for: storage) {}
    }


    @Test func waitersEnterInAdmissionOrder() async throws {
        let fixture = try Fixture(), storage = fixture.storage
        let entered = AsyncStream.makeStream(of: Void.self), queued = AsyncStream.makeStream(of: Void.self)
        var enteredEvents = entered.stream.makeAsyncIterator(), queuedEvents = queued.stream.makeAsyncIterator()
        let release = TestGate(), order = Mutex<[Int]>([])
        let coordinator = LumeRuntimeCoordinator { queued.continuation.yield(()) }
        let holder = Task {
            try await coordinator.withExclusiveAccess(for: storage) {
                entered.continuation.yield(())
                try await release.wait()
            }
        }
        _ = await enteredEvents.next()
        let second = Task {
            try await coordinator.withExclusiveAccess(for: storage) { order.withLock { $0.append(2) } }
        }
        _ = await queuedEvents.next()
        let third = Task {
            try await coordinator.withExclusiveAccess(for: storage) { order.withLock { $0.append(3) } }
        }
        _ = await queuedEvents.next()
        await release.open()
        _ = try await (holder.value, second.value, third.value)
        #expect(order.withLock { $0 } == [2, 3])
    }

}
