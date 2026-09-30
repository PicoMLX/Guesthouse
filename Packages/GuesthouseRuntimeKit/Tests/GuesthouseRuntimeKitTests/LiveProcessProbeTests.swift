import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct LiveProcessProbeTests {
    @Test func observesOnlyTheTestOwnedSleepAndReportsItsExit() async throws {
        let null = try FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null"))
        defer { try? null.close() }
        let before = Date()
        let child = try OwnedChild.spawn(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            environment: [:], workingDirectory: nil, standardInput: null.fileDescriptor,
            standardOutput: null.fileDescriptor, standardError: null.fileDescriptor)
        defer { _ = child.signal(SIGKILL) }
        let probe = LiveProcessProbe()
        let observation = probe.observe(pid: child.processIdentifier)
        if case .present(let live) = observation {
            #expect(live.pid == child.processIdentifier)
            #expect(live.startTime >= before && live.startTime <= Date())
            #expect(live.executablePath == "/bin/sleep")
            #expect(live.argumentsDigest == LiveProcessProbe.digest(["30"]))
            #expect(live.claimedVMName == nil)
            #expect(probe.observe(pid: child.processIdentifier) == observation)
        } else { Issue.record("The test-owned child could not be observed") }
        #expect(child.signal(SIGTERM) == .delivered)
        #expect(await child.waitForReapedExit() == .success(.signal(SIGTERM)))
        // A later reused PID could be present, but it must never reproduce the original facts.
        #expect(probe.observe(pid: child.processIdentifier) != observation)
    }

    @Test(arguments: ["absent", "identity", "path", "arguments", "reuse", "exec", "exit"])
    func unavailableOrChangingEvidenceIsNotAbsence(kind: String) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let identityCalls = Mutex(0), pathCalls = Mutex(0)
        let reads = LiveProcessProbe.Reads(identity: { _ in
            let call = identityCalls.withLock { $0 += 1; return $0 }
            if kind == "absent" || (kind == "exit" && call > 1) { return .absent }
            if kind == "identity" { return .unavailable }
            return .present(start.addingTimeInterval(kind == "reuse" && call > 1 ? 1 : 0))
        }, path: { _ in
            let call = pathCalls.withLock { $0 += 1; return $0 }
            if kind == "path" { return nil }
            return kind == "exec" && call > 1 ? "/different" : "/provider"
        }, arguments: { _ in kind == "arguments" ? nil : ["run", "fixture"] })
        #expect(LiveProcessProbe(reads: reads).observe(pid: 12) == (kind == "absent" ? .absent : .unavailable))
    }

    @Test func invalidPIDDoesNotReadAndProviderParsingIsExplicit() {
        let calls = Mutex(0)
        let reads = LiveProcessProbe.Reads(identity: { _ in
            calls.withLock { $0 += 1 }; return .present(Date(timeIntervalSince1970: 1_800_000_000))
        },
            path: { _ in "/provider" }, arguments: { _ in ["run", "fixture"] })
        let probe = LiveProcessProbe(reads: reads)
        #expect(probe.observe(pid: 0) == .unavailable)
        #expect(calls.withLock { $0 } == 0)
        let claim = probe.observe(pid: 12, claimVM: { arguments in arguments == ["run", "fixture"] ? "fixture" : nil })
        guard case .present(let live) = claim else { Issue.record("Missing fixture observation"); return }
        #expect(live.claimedVMName == "fixture")
    }

    @Test func argumentBoundariesAndEnvironmentArePreservedOrExcluded() {
        let arguments = ["/provider", "run", "", "guesthouse-fixture", ""]
        let data = buffer(argc: 5, strings: arguments + ["SECRET=do-not-retain"])
        #expect(LiveProcessProbe.Reads.parseArguments(data) == Array(arguments.dropFirst()))
        #expect(Set([[], [""], ["a"], ["a", ""], ["a", "b"], ["ab"]].map(LiveProcessProbe.digest)).count == 6)
    }

    @Test(arguments: ["short", "negative", "zero", "huge", "missingPath", "truncated", "utf8", "emptyArgvZero", "aliasArgvZero", "oversized"])
    func malformedArgumentVectorIsUnavailable(kind: String) {
        var data = buffer(argc: 2, strings: ["/provider", "value"])
        switch kind {
        case "short": data = [1, 2, 3]
        case "negative": data = buffer(argc: -1, strings: ["/provider"])
        case "zero": data = buffer(argc: 0, strings: [])
        case "huge": data = buffer(argc: .max, strings: ["/provider"])
        case "missingPath": data = [1, 0, 0, 0, 65, 65]
        case "truncated": data.removeLast()
        case "utf8": data[data.count - 2] = 255
        case "emptyArgvZero": data = buffer(argc: 2, strings: ["", "run", "SECRET=private"])
        case "aliasArgvZero": data = buffer(argc: 2, strings: ["alias", "run"])
        default: data = [UInt8](repeating: 0, count: (2 << 20) + 1)
        }
        #expect(LiveProcessProbe.Reads.parseArguments(data) == nil)
    }

    private func buffer(argc: Int32, strings: [String]) -> [UInt8] {
        var argc = argc
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/provider\0\0".utf8)
        for string in strings { bytes += Array(string.utf8) + [0] }
        return bytes
    }
}
