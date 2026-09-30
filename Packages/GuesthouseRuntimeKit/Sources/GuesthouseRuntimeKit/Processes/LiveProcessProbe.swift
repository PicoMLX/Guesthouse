import CryptoKit
import Darwin
import Foundation
import GuesthouseCore

/// Read-only evidence for a known PID (#24, MVP-PLAN.md §4), adapted from retained #72.
/// Run on a blocking worker, never the GUI or session gate. No process is signaled/adopted.
/// This is not a complete provider inventory and cannot establish that a VM has exited.
public struct LiveProcessProbe: Sendable {
    public enum Observation: Hashable, Sendable {
        case absent
        case present(LiveProcess)
        case unavailable
    }

    enum Identity: Equatable, Sendable {
        case absent
        case present(Date)
        case unavailable
    }

    struct Reads: Sendable {
        var identity: @Sendable (Int32) -> Identity = Self.readIdentity
        var path: @Sendable (Int32) -> String? = Self.readPath
        var arguments: @Sendable (Int32) -> [String]? = Self.readArguments
    }

    private let reads: Reads
    public init() { reads = Reads() }
    init(reads: Reads) { self.reads = reads }

    /// Provider-neutral observation deliberately makes no VM claim. Only a reviewed provider
    /// adapter may interpret an invocation; a matching PID/digest alone never grants ownership.
    public func observe(pid: Int32) -> Observation { observe(pid: pid, claimVM: { _ in nil }) }

    func observe(pid: Int32, claimVM: ([String]) -> String?) -> Observation {
        guard pid > 0 else { return .unavailable }
        let first = reads.identity(pid)
        if first == .absent { return .absent }
        guard case .present(let start) = first,
              let path = reads.path(pid), path.hasPrefix("/"), !path.utf8.contains(0),
              let arguments = reads.arguments(pid), arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            return .unavailable
        }
        // PID reuse or exec during the separate kernel reads invalidates the observation.
        // This is point-in-time evidence, never future signal authority.
        guard reads.identity(pid) == first, reads.path(pid) == path else { return .unavailable }
        return .present(LiveProcess(pid: pid, startTime: start, executablePath: path,
            argumentsDigest: Self.digest(arguments), claimedVMName: claimVM(arguments)))
    }

    /// NUL termination preserves argument boundaries, including empty and trailing arguments.
    /// Raw arguments are bounded temporary input only, never diagnostics or persisted data.
    static func digest(_ arguments: [String]) -> String {
        var bytes = Data()
        for argument in arguments { bytes.append(contentsOf: argument.utf8); bytes.append(0) }
        return "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension LiveProcessProbe.Reads {
    static func readIdentity(_ pid: Int32) -> LiveProcessProbe.Identity {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else {
            return errno == ESRCH ? .absent : .unavailable
        }
        if size == 0 { return .absent }
        guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return .unavailable }
        if info.kp_proc.p_stat == Int8(SZOMB) { return .absent }
        let time = info.kp_proc.p_starttime
        guard time.tv_sec > 0, time.tv_usec >= 0, time.tv_usec < 1_000_000 else { return .unavailable }
        return .present(Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000))
    }

    static func readPath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0, count < buffer.count else { return nil }
        return String(bytes: buffer.prefix(Int(count)), encoding: .utf8)
    }

    static func readArguments(_ pid: Int32) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 2 << 20 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, UInt32(name.count), &bytes, &size, nil, 0) == 0,
              size <= bytes.count else { return nil }
        return parseArguments(Array(bytes.prefix(size)))
    }

    /// KERN_PROCARGS2: argc, executable path, NUL padding, argc NUL-terminated argv entries.
    /// Discard argv[0] and stop before environment strings; truncated vectors are unavailable.
    static func parseArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4, bytes.count <= 2 << 20 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc <= bytes.count - 4 else { return nil }
        guard let pathEnd = bytes[4...].firstIndex(of: 0), pathEnd > 4,
              let executable = String(bytes: bytes[4..<pathEnd], encoding: .utf8) else { return nil }
        var cursor = pathEnd
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for index in 0..<argc {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  let value = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            // Our spawner uses the executable path as argv[0]. Reject other shapes rather
            // than skip an empty argv[0] as padding and misread environment bytes as arguments.
            if index == 0, value != executable { return nil }
            if index > 0 { result.append(value) }
            cursor = end + 1
        }
        return result
    }
}
