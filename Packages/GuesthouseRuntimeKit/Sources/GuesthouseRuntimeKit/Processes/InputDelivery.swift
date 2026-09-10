import Darwin
import Foundation
import Synchronization

/// Retains #69's asynchronous stdin delivery, never changing process-wide SIGPIPE policy.
final class InputDelivery: Sendable {
    enum End: Equatable, Sendable { case pending, delivered, failed(Int32), abandoned }
    private final class Storage: Sendable {
        struct State { var end = End.pending; var started = false; var closedSuccessfully = false }
        let state = Mutex(State())
        let closed = DispatchGroup()
    }
    private static let queue = DispatchQueue(label: "GuesthouseRuntimeKit.stdin", qos: .utility, attributes: .concurrent)
    private let storage: Storage
    private let channel: DispatchIO

    /// Takes the writer only on success. DispatchIO cleanup alone closes the borrowed fd.
    init(_ writer: FileHandle) throws {
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw ProcessLaunchFailure.pipeUnavailable }
        let storage = Storage()
        storage.closed.enter()
        self.storage = storage
        channel = DispatchIO(type: .stream, fileDescriptor: writer.fileDescriptor, queue: Self.queue) { error in
            let closedSuccessfully: Bool
            do { try writer.close(); closedSuccessfully = true } catch { closedSuccessfully = false }
            storage.state.withLock { state in
                state.closedSuccessfully = closedSuccessfully
                if state.end == .pending { state.end = .failed(error == 0 ? EIO : error) }
            }
            storage.closed.leave()
        }
    }
    deinit { cancel() }

    /// Called once, only after the run owner has armed its lifetime deadline.
    func start(_ data: Data) {
        let admitted = storage.state.withLock { state in
            guard !state.started, state.end == .pending else { return false }
            state.started = true
            return true
        }
        guard admitted else { return }
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: Self.queue) { [storage, channel] done, remainder, error in
            guard done || error != 0 else { return }
            storage.state.withLock { state in
                guard state.end == .pending else { return }
                state.end = error == 0 && (remainder?.isEmpty ?? true) ? .delivered : .failed(error == 0 ? EIO : error)
            }
            channel.close(flags: error == 0 ? [] : .stop)
        }
    }
    func cancel() {
        storage.state.withLock { state in
            if state.end == .pending { state.end = .abandoned }
        }
        channel.close(flags: .stop)
    }
    var end: End { storage.state.withLock { $0.end } }

    /// Dedicated dispatch waiter only, not a cooperative task or actor.
    func waitUntilClosed(by deadline: DispatchTime) -> Bool {
        if storage.closed.wait(timeout: deadline) == .success {
            return storage.state.withLock { $0.closedSuccessfully }
        }
        cancel()
        return false
    }
}
