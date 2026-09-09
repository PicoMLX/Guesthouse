import Darwin
import Foundation
import Synchronization

/// The nonblocking pipe owner retained from #69, with ADR 0003's temporary byte capture.
/// Runtime adapters may parse a complete response; these bytes are NEVER diagnostics.
/// No text decoding, record splitting, redaction, logging, Codable or XPC bridge exists here.
final class OutputReaders: Sendable {
    enum Kind: Hashable, Sendable { case stdout, stderr }
    enum End: Equatable, Sendable { case notAttached, active, eof, abandoned, failed(Int32) }
    enum Failure: Error, Equatable, Sendable { case closed, duplicateStream, configure(Int32) }
    struct Response: Sendable {
        let stdout: Data, stderr: Data
        let stdoutEnd: End, stderrEnd: End
        let truncated: Bool
        /// Only output completeness, NEVER process/descendant quiescence or mutation success.
        var isComplete: Bool { stdoutEnd == .eof && stderrEnd == .eof && !truncated }
    }
    static let captureCeiling = 16 << 20
    let maximumBytes: Int
    private let capturing: Set<Kind>
    private let drained = DispatchGroup()
    private struct State {
        var handles: [Kind: FileHandle] = [:]
        var ends: [Kind: End] = [:]
        var stdout = Data(), stderr = Data()
        var captured = 0
        var truncated = false, sealed = false, taken = false
    }
    private let state = Mutex(State())

    /// Discard both streams by default. Selected streams share ONE clamped byte budget.
    init(maximumBytes: Int = 0, capturing: Set<Kind> = []) {
        self.maximumBytes = min(Self.captureCeiling, max(0, maximumBytes))
        self.capturing = capturing
    }
    deinit { detach() }

    /// Takes ownership on success. The caller must not read, close or reuse this handle.
    /// At most one handle per stream; all attachment finishes before waiting/taking output.
    func attach(_ handle: FileHandle, kind: Kind) throws {
        try state.withLock { state in
            guard !state.sealed else { throw Failure.closed }
            guard state.ends[kind] == nil, !state.handles.values.contains(where: { $0 === handle }) else {
                throw Failure.duplicateStream
            }
            let descriptor = handle.fileDescriptor
            guard !state.handles.values.contains(where: { $0.fileDescriptor == descriptor }) else {
                throw Failure.duplicateStream
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw Failure.configure(errno)
            }
            drained.enter()
            state.handles[kind] = handle; state.ends[kind] = .active
            let id = ObjectIdentifier(handle)
            handle.readabilityHandler = { [weak self] _ in self?.readAvailable(kind, id: id) }
        }
    }

    /// Closes pending pipes, even when a surviving writer never sends EOF. Idempotent.
    /// Does not signal any process or claim that closing the pipes stopped a descendant.
    func detach() {
        state.withLock { state in
            state.sealed = true
            for kind in Array(state.handles.keys) { close(kind, end: .abandoned, state: &state) }
        }
    }

    /// Blocking wait for a dedicated noncooperative queue, never an actor/cooperative task.
    /// The run owner can detach to end this wait early at its own deadline or cancellation.
    @discardableResult
    func waitUntilDrained(by deadline: DispatchTime) -> DispatchTimeoutResult {
        state.withLock { $0.sealed = true } // No future enter can race a completed group.
        let result = drained.wait(timeout: deadline)
        if result == .timedOut { detach() }
        return result
    }

    /// Transfers the bounded response once, after EOF/detach, and releases retained bytes.
    /// An incomplete response must not be parsed as a complete command result.
    func takeResponse() -> Response? {
        state.withLock { state in
            guard state.sealed, state.handles.isEmpty, !state.taken else { return nil }
            state.taken = true
            let response = Response(stdout: state.stdout, stderr: state.stderr,
                stdoutEnd: state.ends[.stdout] ?? .notAttached, stderrEnd: state.ends[.stderr] ?? .notAttached,
                truncated: state.truncated)
            state.stdout.removeAll(); state.stderr.removeAll()
            return response
        }
    }

    private func readAvailable(_ kind: Kind, id: ObjectIdentifier) {
        state.withLock { state in
            // A queued callback after detach cannot touch a closed or subsequently reused fd.
            guard let handle = state.handles[kind], ObjectIdentifier(handle) == id else { return }
            var bytes = [UInt8](repeating: 0, count: 16 << 10)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0, capturing.contains(kind) {
                let keep = min(count, maximumBytes - state.captured)
                if kind == .stdout { state.stdout.append(contentsOf: bytes.prefix(keep)) }
                else { state.stderr.append(contentsOf: bytes.prefix(keep)) }
                state.captured += keep
                if keep < count { state.truncated = true }
            } else if count == 0 {
                close(kind, end: .eof, state: &state)
            } else if count < 0, errno != EAGAIN, errno != EINTR {
                close(kind, end: .failed(errno), state: &state)
            }
            // Unselected bytes and all bytes beyond the cap are drained and discarded.
        }
    }

    /// Reads, closure and drain-group departure share the same mutex; callbacks never reenter.
    private func close(_ kind: Kind, end: End, state: inout State) {
        guard let handle = state.handles.removeValue(forKey: kind) else { return }
        handle.readabilityHandler = nil
        try? handle.close()
        state.ends[kind] = end
        drained.leave()
    }
}
