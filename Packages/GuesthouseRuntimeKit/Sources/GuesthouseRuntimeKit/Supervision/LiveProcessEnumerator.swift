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
    /// What one scan of the process table found: the processes it could read, and whether any
    /// process that looked like a candidate could not be read. An unreadable candidate is not
    /// evidence of absence, so callers treat it as uncertainty rather than as "nothing there".
    public struct Candidates: Sendable {
        public var processes: [LiveProcess]
        public var unreadable: Bool

        public init(processes: [LiveProcess], unreadable: Bool) {
            self.processes = processes
            self.unreadable = unreadable
        }
    }

    public func candidates(executable: URL?, pid: Int32?) -> Candidates {
        var seen: Set<Int32> = []
        var result: [LiveProcess] = []
        var unreadable = false
        if let pid {
            switch observe(pid: pid) {
            case .present(let process):
                seen.insert(pid)
                result.append(process)
            case .unavailable:
                seen.insert(pid)
                unreadable = true
            case .absent:
                break
            }
        }
        guard let executable else { return Candidates(processes: result, unreadable: unreadable) }
        for candidate in allPIDs() where !seen.contains(candidate) {
            guard let path = executablePath(pid: candidate), path == executable.path else { continue }
            switch observe(pid: candidate) {
            case .present(let process): result.append(process)
            // The process runs the recorded program but could not be read: it may be a
            // claimant, so its absence from the list must not be read as an exit.
            case .unavailable: unreadable = true
            case .absent: break
            }
        }
        return Candidates(processes: result, unreadable: unreadable)
    }

    /// What the process table says about one PID. "Absent" and "unreadable" are different
    /// answers: a process that exists but cannot be read (another user's, or a transient
    /// failure) must not be mistaken for one that exited.
    public enum Observation: Hashable, Sendable {
        case absent
        case present(LiveProcess)
        case unavailable(reason: String)
    }

    public func observe(pid: Int32) -> Observation {
        guard pid > 0 else { return .absent }
        if kill(pid, 0) != 0, errno == ESRCH { return .absent }
        guard let first = startTime(pid: pid) else { return .unavailable(reason: "start time unreadable") }
        guard let path = executablePath(pid: pid) else { return .unavailable(reason: "executable path unreadable") }
        guard let arguments = arguments(pid: pid) else { return .unavailable(reason: "arguments unreadable") }
        // The fields came from separate calls; if the PID was reused in between, the start
        // time has changed and the observation describes two processes, so it is discarded.
        guard startTime(pid: pid) == first else { return .unavailable(reason: "process replaced during observation") }
        return .present(LiveProcess(pid: pid, startTime: first, executablePath: path, argumentsDigest: Self.digest(of: arguments), claimedVMName: Self.claimedVMName(in: arguments)))
    }

    /// Every readable process whose arguments name `vmName`, and whether any process could
    /// not be read. Used to notice a launch that has not taken the VM's lock yet.
    public func claimants(ofVM vmName: String) -> Candidates {
        var found: [LiveProcess] = []
        var unreadable = false
        for candidate in allPIDs() {
            guard let arguments = arguments(pid: candidate) else { continue }
            guard Self.claimedVMName(in: arguments) == vmName else { continue }
            switch observe(pid: candidate) {
            case .present(let process): found.append(process)
            case .unavailable: unreadable = true
            case .absent: break
            }
        }
        return Candidates(processes: found, unreadable: unreadable)
    }

    /// The identity of one running process, or `nil` if it does not exist or cannot be read.
    public func live(pid: Int32) -> LiveProcess? {
        if case .present(let process) = observe(pid: pid) { return process }
        return nil
    }

    /// The VM a `tart run <name> …` invocation names, if it is an app-managed VM name; any
    /// other argument shape yields `nil`. Only the first positional argument after `run`
    /// counts, so a flag value can never be taken for a name.
    public static func claimedVMName(in arguments: [String]) -> String? {
        guard let run = arguments.firstIndex(of: "run") else { return nil }
        guard let name = arguments[arguments.index(after: run)...].first(where: { !$0.hasPrefix("-") }) else { return nil }
        return (try? RequestValidator.validateVMName(name)) == nil ? nil : name
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
