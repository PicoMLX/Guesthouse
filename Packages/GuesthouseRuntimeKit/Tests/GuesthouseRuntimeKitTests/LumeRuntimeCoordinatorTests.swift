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
    private func storage(_ name: String = UUID().uuidString) throws -> RuntimeStorage {
        try RuntimeStorage(root: FileManager.default.temporaryDirectory
            .appending(path: "LumeRuntimeCoordinatorTests")
            .appending(path: name))
    }

    @Test func launchAndReplacementShareTheSameRootLease() async throws {
        let storage = try storage()
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
        let firstStorage = try storage()
        let secondStorage = try storage()
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
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "LumeRuntimeCoordinatorAlias-\(UUID().uuidString)")
        let realParent = parent.appending(path: "real")
        let aliasParent = parent.appending(path: "alias")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: realParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)
        let firstStorage = try RuntimeStorage(root: realParent.appending(path: "storage"))
        let secondStorage = try RuntimeStorage(root: aliasParent.appending(path: "storage"))
        #expect(firstStorage.root.path != secondStorage.root.path)
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
        let storage = try storage()
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
        let storage = try storage()
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
        let first = try storage()
        let second = try storage()
        let coordinator = LumeRuntimeCoordinator()

        await #expect(throws: LumeRuntimeCoordinationError.nestedAcquisition) {
            try await coordinator.withExclusiveAccess(for: first) {
                try await coordinator.withExclusiveAccess(for: second) {}
            }
        }
    }

    @Test func inheritedContextExpiresWithItsLease() async throws {
        let storage = try storage()
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
}
