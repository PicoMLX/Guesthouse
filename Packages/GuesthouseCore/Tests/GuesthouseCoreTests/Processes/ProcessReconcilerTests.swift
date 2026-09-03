import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProcessReconcilerTests {
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let environment = EnvironmentID()

    var recorded: ProcessIdentity {
        ProcessIdentity(pid: 4242, startTime: started, executablePath: "/Library/Application Support/Guesthouse/runtime/2.36.0/Tart.app/Contents/MacOS/tart", argumentsDigest: "sha256:abc", vmName: environment.tartVMName, environmentID: environment, recordedAt: started.addingTimeInterval(1))
    }

    func live(pid: Int32 = 4242, start: Date? = nil, path: String? = nil, digest: String = "sha256:abc", vm: String? = nil) -> LiveProcess {
        LiveProcess(pid: pid, startTime: start ?? started, executablePath: path ?? recorded.executablePath, argumentsDigest: digest, claimedVMName: vm ?? environment.tartVMName)
    }

    @Test func exactMatchIsOwned() {
        let process = live()
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(pid: 1, digest: "sha256:other", vm: "guesthouse-other"), process], vmLockPresent: true) == .ownedRunning(process))
        // The start time is an identity: a fraction of a second off is another process.
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(start: started.addingTimeInterval(0.4))], vmLockPresent: true) == .uncertain(.pidReusedByAnotherProcess))
    }

    @Test func anotherProcessClaimingTheVMPreventsASafeStart() {
        let sameInvocation = live(pid: 9, start: started.addingTimeInterval(5))
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [sameInvocation], vmLockPresent: false) == .uncertain(.anotherProcessClaimsVM))
        let namesTheVM = live(pid: 10, digest: "sha256:flags")
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [namesTheVM], vmLockPresent: false) == .uncertain(.anotherProcessClaimsVM))
        let unrelated = live(pid: 11, digest: "sha256:flags", vm: "guesthouse-other")
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [unrelated], vmLockPresent: false) == .exited)
    }

    @Test func aProcessThatDoesNotNameTheRecordedVMIsUncertain() {
        // The record pairs this environment with another VM's invocation: the live process
        // says which VM it runs, and it is not this one.
        let other = EnvironmentID().tartVMName
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(vm: other)], vmLockPresent: true) == .uncertain(.vmNameUnconfirmed))
        // Arguments that cannot be read as a VM launch prove nothing either.
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(vm: "")], vmLockPresent: true) == .uncertain(.vmNameUnconfirmed))
    }

    @Test func aCompetingClaimantIsUncertainEvenWhileTheRecordedProcessLives() {
        let competitor = live(pid: 77, digest: "sha256:flags")
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(), competitor], vmLockPresent: true) == .uncertain(.anotherProcessClaimsVM))
        let sameInvocation = live(pid: 78)
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(), sameInvocation], vmLockPresent: true) == .uncertain(.anotherProcessClaimsVM))
        let unrelated = live(pid: 79, digest: "sha256:other", vm: "guesthouse-other")
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(), unrelated], vmLockPresent: true) == .ownedRunning(live()))
    }

    @Test func anInconsistentRecordNeverGrantsOwnership() {
        var wrong = recorded
        wrong.vmName = EnvironmentID().tartVMName
        #expect(!wrong.isConsistent)
        #expect(ProcessReconciler.reconcile(recorded: wrong, observed: [live()], vmLockPresent: true) == .uncertain(.recordInconsistent))
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
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(pid: 7, digest: "sha256:other", vm: "guesthouse-other")], vmLockPresent: false) == .exited)
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
