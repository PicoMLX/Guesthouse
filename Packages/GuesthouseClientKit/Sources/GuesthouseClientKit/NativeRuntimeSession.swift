import Foundation
import GuesthouseCore
import Synchronization
import XPC

protocol RuntimeClientSession: AnyObject, Sendable {
    func activate() throws
    func send(_ payload: Data, reply: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void)
    /// Must safely dispose of an inactive candidate as well as an active session.
    func cancel()
}

/// Owns exactly one initially inactive XPC session. Never expose the native handle.
/// SDK session.h requires activation before cancellation/release, and forbids sends after
/// cancellation. The lifecycle lock serializes our activate/send/cancel calls. Native XPC
/// callbacks are asynchronous/non-preemptive; they never run inline under this lock.
final class NativeRuntimeSession: RuntimeClientSession {
    private enum Phase { case inactive, active, closed }
    private let phase = Mutex(Phase.inactive)
    private let native: XPCSession

    init(_ inactiveSession: XPCSession) { native = inactiveSession }
    deinit { cancel() }

    func activate() throws(RuntimeSessionFailure) {
        try phase.withLock { (phase: inout Phase) throws(RuntimeSessionFailure) in
            guard phase == .inactive else { throw RuntimeSessionFailure(cause: .connectionLost) }
            do { try native.activate(); phase = .active }
            catch { phase = .closed; throw RuntimeSessionFailure(cause: .connectionLost) }
        }
    }

    func cancel() {
        phase.withLock { phase in
            guard phase != .closed else { return }
            let wasInactive = phase == .inactive
            phase = .closed
            // An uninstalled candidate still needs legal disposal. Failed activation already
            // cancels it. No request is sent, even if cancellation wins before installation.
            if wasInactive { do { try native.activate() } catch { return } }
            native.cancel(reason: "Guesthouse client session retired")
        }
    }

    func send(_ payload: Data, reply: @escaping @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void) {
        let sent = phase.withLock { phase in
            guard phase == .active, let frame = try? RawRuntimeFrame.encode(
                payload, protocolVersion: Int64(RuntimeProtocolVersion.current.rawValue)) else { return false }
            native.send(message: frame) { result in
                switch result {
                case .success(let message): reply(Self.decode(message))
                case .failure: reply(.failure(RuntimeSessionFailure(cause: .connectionLost)))
                }
            }
            return true
        }
        if !sent { reply(.failure(RuntimeSessionFailure(cause: .connectionLost))) }
    }

    /// Reply and push share the ORIGINAL native frame checks before any JSON decoder.
    static func decode(_ message: XPCDictionary) -> Result<RuntimeEvent, RuntimeSessionFailure> {
        let payload: Data
        do { payload = try RawRuntimeFrame.payload(message, expectedVersion: Int64(RuntimeProtocolVersion.current.rawValue)) }
        catch { return .failure(.frameFailure(error)) }
        do { return .success(try RuntimeEventEnvelope.decode(payload).event) }
        catch {
            // The outer version is current: a foreign inner version is a contradiction,
            // not a compatible handshake with an older service. Never forward decoder text.
            if case .protocolMismatch = error { return .failure(.init(cause: .malformedResponse)) }
            return .failure(.decodingFailure(error))
        }
    }
}
