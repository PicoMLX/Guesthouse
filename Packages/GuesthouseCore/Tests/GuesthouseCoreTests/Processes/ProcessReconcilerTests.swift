import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ProcessReconcilerTests {
    @Test func reconcilerConformsToSendable() {
        // Require the enum itself to conform, not just its always-sendable metatype value.
        func requiringSendable<T: Sendable>(_ type: T.Type) {}
        requiringSendable(ProcessReconciler.self)
    }

    let started = Date(timeIntervalSince1970: 1_800_000_000)
    let environment = EnvironmentID()

    var recorded: ProcessIdentity {
        ProcessIdentity(pid: 4242, startTime: started, executablePath: "/Library/Application Support/Guesthouse/runtime/provider", argumentsDigest: "sha256:" + String(repeating: "a", count: 64), vmName: environment.managedVMName, environmentID: environment, recordedAt: started.addingTimeInterval(1))
    }

    func live(pid: Int32 = 4242, start: Date? = nil, path: String? = nil, digest: String = "sha256:" + String(repeating: "a", count: 64), vm: String? = nil) -> LiveProcess {
        LiveProcess(pid: pid, startTime: start ?? started, executablePath: path ?? recorded.executablePath, argumentsDigest: digest, claimedVMName: vm ?? environment.managedVMName)
    }

    @Test func exactMatchIsOwned() {
        let process = live()
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(pid: 1, digest: "sha256:other", vm: "guesthouse-other"), process], observationComplete: true, vmLockPresent: true) == .ownedRunning(process))
        // The start time is an identity: a fraction of a second off is another process.
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(start: started.addingTimeInterval(0.4))], observationComplete: true, vmLockPresent: true) == .uncertain(.pidReusedByAnotherProcess))
    }

    @Test func anotherProcessClaimingTheVMPreventsASafeStart() {
        let sameInvocation = live(pid: 9, start: started.addingTimeInterval(5))
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [sameInvocation], observationComplete: true, vmLockPresent: false) == .uncertain(.anotherProcessClaimsVM))
        let namesTheVM = live(pid: 10, digest: "sha256:flags")
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [namesTheVM], observationComplete: true, vmLockPresent: false) == .uncertain(.anotherProcessClaimsVM))
        let unrelated = live(pid: 11, digest: "sha256:flags", vm: "guesthouse-other")
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [unrelated], observationComplete: true, vmLockPresent: false) == .exited)
    }

    @Test func aProcessThatDoesNotNameTheRecordedVMIsUncertain() {
        // The record pairs this environment with another VM's invocation: the live process
        // says which VM it runs, and it is not this one.
        let other = EnvironmentID().managedVMName
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(vm: other)], observationComplete: true, vmLockPresent: true) == .uncertain(.vmNameUnconfirmed))
        // Arguments that cannot be read as a VM launch prove nothing either.
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(vm: "")], observationComplete: true, vmLockPresent: true) == .uncertain(.vmNameUnconfirmed))
    }

    @Test func aCompetingClaimantIsUncertainEvenWhileTheRecordedProcessLives() {
        let competitor = live(pid: 77, digest: "sha256:flags")
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(), competitor], observationComplete: true, vmLockPresent: true) == .uncertain(.anotherProcessClaimsVM))
        let sameInvocation = live(pid: 78)
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(), sameInvocation], observationComplete: true, vmLockPresent: true) == .uncertain(.anotherProcessClaimsVM))
        let unrelated = live(pid: 79, digest: "sha256:other", vm: "guesthouse-other")
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(), unrelated], observationComplete: true, vmLockPresent: true) == .ownedRunning(live()))
    }

    @Test func anInconsistentRecordNeverGrantsOwnership() {
        var wrong = recorded
        wrong.vmName = EnvironmentID().managedVMName
        #expect(!wrong.isConsistent)
        #expect(ProcessReconciler.reconcile(recorded: wrong, observed: [live()], observationComplete: true, vmLockPresent: true) == .uncertain(.recordInconsistent))
    }

    @Test func pidReuseIsUncertain() {
        let reused = live(start: started.addingTimeInterval(3600))
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [reused], observationComplete: true, vmLockPresent: false) == .uncertain(.pidReusedByAnotherProcess))
    }

    @Test func executableOrArgumentMismatchIsUncertain() {
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(path: "/usr/bin/yes")], observationComplete: true, vmLockPresent: false) == .uncertain(.executableMismatch))
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(digest: "sha256:other")], observationComplete: true, vmLockPresent: false) == .uncertain(.argumentsMismatch))
    }

    @Test func goneWithoutLockIsExitedButGoneWithLockIsUncertain() {
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(pid: 7, digest: "sha256:other", vm: "guesthouse-other")], observationComplete: true, vmLockPresent: false) == .exited)
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [], observationComplete: true, vmLockPresent: true) == .uncertain(.lockHeldWithoutProcess))
    }

    @Test func multipleCandidatesAreUncertain() {
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: [live(), live()], observationComplete: true, vmLockPresent: true) == .uncertain(.multipleCandidates))
    }

    @Test func uncertainNeverLooksLikeSafeToStart() {
        let verdicts: [OwnershipVerdict] = [
            ProcessReconciler.reconcile(recorded: recorded, observed: [live(start: started.addingTimeInterval(10))], observationComplete: true, vmLockPresent: false),
            ProcessReconciler.reconcile(recorded: recorded, observed: [], observationComplete: true, vmLockPresent: true),
        ]
        for verdict in verdicts {
            #expect(verdict != .exited)
            if case .ownedRunning = verdict { Issue.record("uncertain verdict reported as owned") }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func incompleteEvidenceCannotAuthorizeOwnershipOrExit(hasCandidate: Bool, missingLock: Bool) {
        #expect(ProcessReconciler.reconcile(recorded: recorded, observed: hasCandidate ? [live()] : [],
            observationComplete: missingLock, vmLockPresent: missingLock ? nil : false)
            == .uncertain(missingLock ? .inventoryUnavailable : .processUnobservable))
    }

    @Test(arguments: ["pid", "time", "path", "nul", "digest", "timestamp"])
    func malformedRecordCannotBecomeOwned(field: String) {
        var value = recorded
        switch field {
        case "pid": value.pid = 0
        case "time": value.startTime = Date(timeIntervalSince1970: .nan)
        case "path": value.executablePath = "relative/provider"
        case "nul": value.executablePath = "/provider\0suffix"
        case "digest": value.argumentsDigest = "sha256:"
        default: value.recordedAt = Date(timeIntervalSince1970: .infinity)
        }
        let same = LiveProcess(pid: value.pid, startTime: value.startTime, executablePath: value.executablePath,
            argumentsDigest: value.argumentsDigest, claimedVMName: value.vmName)
        #expect(ProcessReconciler.reconcile(recorded: value, observed: [same], observationComplete: true,
            vmLockPresent: false) == .uncertain(.recordInconsistent))
    }

    @Test func verdictsRoundTripAndLegacyNameIsUnchanged() throws {
        #expect(environment.managedVMName == environment.tartVMName)
        let values: [OwnershipVerdict] = [.ownedRunning(live()), .exited, .uncertain(.processUnobservable)]
        for value in values {
            #expect(try JSONDecoder().decode(OwnershipVerdict.self, from: JSONEncoder().encode(value)) == value)
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
