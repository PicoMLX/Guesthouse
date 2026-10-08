import Darwin
import Foundation
import Synchronization

/// Asynchronous stdin delivery with bounded nonblocking writes and descriptor-local SIGPIPE policy.
final class InputDelivery: Sendable {
    enum End: Equatable, Sendable { case pending, delivered, failed(Int32), abandoned }
    private final class Storage: Sendable {
        struct State {
            var end = End.pending
            var activated = false, started = false, closedSuccessfully = false
            var data: Data?
            var offset = 0
        }
        let state = Mutex(State())
        let closed = DispatchGroup()
    }
    private let storage: Storage
    private let source: any DispatchSourceWrite
    private let descriptor: Int32

    /// Takes the writer only on success. Only the source's cancellation handler closes it,
    /// after the system has relinquished the descriptor and the last write handler returned.
    init(_ writer: FileHandle) throws {
        let descriptor = writer.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw ProcessLaunchFailure.pipeUnavailable }
        let storage = Storage()
        storage.closed.enter()
        self.storage = storage
        self.descriptor = descriptor
        source = DispatchSource.makeWriteSource(fileDescriptor: descriptor,
            queue: DispatchQueue(label: "GuesthouseRuntimeKit.stdin", qos: .utility))
        source.setCancelHandler {
            let closedSuccessfully: Bool
            do { try writer.close(); closedSuccessfully = true } catch { closedSuccessfully = false }
            storage.state.withLock { $0.closedSuccessfully = closedSuccessfully }
            storage.closed.leave()
        }
        source.setEventHandler { [weak self] in self?.writeAvailable() }
    }
    deinit { cancel() }

    /// Called once, only after the run owner has armed its lifetime deadline.
    func start(_ data: Data) {
        storage.state.withLock { state in
            guard !state.started, state.end == .pending else { return }
            state.started = true
            state.data = data
            if data.isEmpty { state.end = .delivered; state.data = nil; source.cancel() }
            activate(&state)
        }
    }
    func cancel() {
        storage.state.withLock { state in
            if state.end == .pending { state.end = .abandoned }
            state.data = nil
            source.cancel()
            activate(&state) // An unstarted source must become active to deliver its cleanup.
        }
    }
    var end: End { storage.state.withLock { $0.end } }

    private func activate(_ state: inout Storage.State) {
        guard !state.activated else { return }
        state.activated = true
        source.activate()
    }

    private func writeAvailable() {
        storage.state.withLock { state in
            guard state.end == .pending, let data = state.data else { return }
            // Readiness is advisory. Never block this queue or a cooperative executor,
            // and bound each callback so cancellation can fence the next write.
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: state.offset),
                    min(16 << 10, data.count - state.offset))
            }
            if count > 0 {
                state.offset += count
                if state.offset < data.count { return }
                state.end = .delivered
            } else {
                let error = count < 0 ? errno : EIO
                if error == EAGAIN || error == EINTR { return }
                state.end = .failed(error)
            }
            state.data = nil
            source.cancel()
        }
    }

    /// Dedicated dispatch waiter only, not a cooperative task or actor. Cancellation alone
    /// is never closure evidence: report success only after the actual FileHandle close.
    func waitUntilClosed(by deadline: DispatchTime) -> Bool {
        if storage.closed.wait(timeout: deadline) == .success {
            return storage.state.withLock { $0.closedSuccessfully }
        }
        cancel()
        return false
    }
}
