import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProcessReconcilerTests {
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let environment = EnvironmentID()

    var recorded: ProcessIdentity {
        ProcessIdentity(pid: 4242, startTime: started, executablePath: "/Library/Application Support/Guesthouse/runtime/2.36.0/Tart.app/Contents/MacOS/tart", argumentsDigest: "sha256:abc", vmName: environment.tartVMName, environmentID: environment, recordedAt: started.addingTimeInterval(1))
    }

    func live(pid: Int32 = 4242, start: Date? = nil, path: String? = nil, digest: String = "sha256:abc") -> LiveProcess {
        LiveProcess(pid: pid, startTime: start ?? started, executablePath: path ?? recorded.executablePath, argumentsDigest: digest)
    }

    @Test func exactMatchIsOwned() {
        let process = live(start: started.addingTimeInterval(0.4))
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(pid: 1), process], vmLockPresent: true) == .ownedRunning(process))
    }

    @Test func pidReuseIsUncertain() {
        let reused = live(start: started.addingTimeInterval(3600))
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [reused], vmLockPresent: false) == .uncertain(.pidReusedByAnotherProcess))
    }

    @Test func executableOrArgumentMismatchIsUncertain() {
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(path: "/usr/bin/yes")], vmLockPresent: false) == .uncertain(.executableMismatch))
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(digest: "sha256:other")], vmLockPresent: false) == .uncertain(.argumentsMismatch))
    }

    @Test func goneWithoutLockIsExitedButGoneWithLockIsUncertain() {
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(pid: 7)], vmLockPresent: false) == .exited)
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [], vmLockPresent: true) == .uncertain(.lockHeldWithoutProcess))
    }

    @Test func multipleCandidatesAreUncertain() {
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(), live()], vmLockPresent: true) == .uncertain(.multipleCandidates))
    }

    @Test func uncertainNeverLooksLikeSafeToStart() {
        let verdicts: [OwnershipVerdict] = [
            ProcessReconciler.reconcile(recorded: recorded, observed: [live(start: started.addingTimeInterval(10))], vmLockPresent: false),
            ProcessReconciler.reconcile(recorded: recorded, observed: [], vmLockPresent: true),
        ]
        for verdict in verdicts {
            #expect(verdict != .exited)
            if case .ownedRunning = verdict { Issue.record("uncertain verdict reported as owned") }
        }
    }

    @Test func identitiesRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(recorded)
        #expect(try JSONDecoder().decode(ProcessIdentity.self, from: data) == recorded)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("--vnc"), "arguments are stored as a digest, never verbatim")
        let liveData = try JSONEncoder().encode(live())
        #expect(try JSONDecoder().decode(LiveProcess.self, from: liveData) == live())
    }
}
