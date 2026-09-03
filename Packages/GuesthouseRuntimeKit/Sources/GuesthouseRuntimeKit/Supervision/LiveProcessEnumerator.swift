import CryptoKit
import Darwin
import Foundation
import GuesthouseCore

/// Reads the process table to produce `LiveProcess` values for reconciliation
/// (MVP-PLAN.md §4: identify any surviving Tart process and its exact VM before recovering
/// control). Pure observation; nothing here signals or kills.
public struct LiveProcessEnumerator: Sendable {
    public init() {}

    /// Every process the current user can inspect whose executable is `executable`, plus the
    /// process with `pid` if it exists (whatever it runs), so a reused PID is still observed.
    public func candidates(executable: URL?, pid: Int32?) -> [LiveProcess] {
        var seen: Set<Int32> = []
        var result: [LiveProcess] = []
        if let pid, let process = live(pid: pid) {
            seen.insert(pid)
            result.append(process)
        }
        guard let executable else { return result }
        for candidate in allPIDs() where !seen.contains(candidate) {
            guard let path = executablePath(pid: candidate), path == executable.path, let process = live(pid: candidate) else { continue }
            result.append(process)
        }
        return result
    }

    /// The identity of one running process, or `nil` if it does not exist or cannot be read.
    public func live(pid: Int32) -> LiveProcess? {
        guard let first = startTime(pid: pid), let path = executablePath(pid: pid) else { return nil }
        let digest = Self.digest(of: arguments(pid: pid) ?? [])
        // The fields came from separate calls; if the PID was reused in between, the start
        // time has changed and the observation describes two processes, so it is discarded.
        guard startTime(pid: pid) == first else { return nil }
        return LiveProcess(pid: pid, startTime: first, executablePath: path, argumentsDigest: digest)
    }

    /// The digest `ProcessIdentity` records for a launch: SHA-256 over the arguments joined by
    /// NUL, never the arguments themselves.
    public static func digest(of arguments: [String]) -> String {
        let joined = Data(arguments.joined(separator: "\0").utf8)
        return "sha256:" + SHA256.hash(data: joined).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Process table

    func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count) * Int32(MemoryLayout<Int32>.size))
        }
        return Array(pids.prefix(Int(max(0, filled)))).filter { $0 > 0 }
    }

    func executablePath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a macro (4 * MAXPATHLEN) that Swift does not import.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func startTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Arguments as the kernel recorded them at exec, without the executable path.
    func arguments(pid: Int32) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, UInt32(name.count), &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { $0.load(as: Int32.self) })
        var cursor = MemoryLayout<Int32>.size
        // Skip the executable path and its padding NULs.
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }
        var strings: [String] = []
        var current: [UInt8] = []
        while cursor < size, strings.count < argc {
            let byte = buffer[cursor]
            if byte == 0 {
                strings.append(String(decoding: current, as: UTF8.self))
                current.removeAll()
            } else {
                current.append(byte)
            }
            cursor += 1
        }
        // argv[0] is the program name; ProcessIdentity records the arguments after it.
        return Array(strings.dropFirst())
    }
}
