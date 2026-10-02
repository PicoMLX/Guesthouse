import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct LumeProbeSequenceTests {
    private final class Fixture: Sendable {
        let base, root: URL
        let owner: StateStore
        let storage: RuntimeStorage
        var record: URL { root.appending(path: "state/lume-ownership.json") }
        init() async throws {
            var template = Array("/private/tmp/guesthouse-probe-sequence-XXXXXX".utf8CString)
            base = URL(fileURLWithPath: String(cString: try #require(mkdtemp(&template))))
            root = base.appending(path: "Guesthouse")
            let root = root
            owner = try await StateStore.createFresh(root: { root })
            storage = try RuntimeStorage(existingRoot: root)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func saved() throws -> LumeRuntimeOwnership {
            try JSONDecoder().decode(LumeRuntimeOwnership.self, from: Data(contentsOf: record))
        }
        // Real completion evidence from benign fixtures, not the strictly gated provider
        // entry. No signature override, fabricated child/report or saved cleanup proof.
        func step(_ command: LumeLaunchIntent.Command, truncate: Bool = false,
                  storageAdvertised: Bool = true, diagnostic: @escaping @Sendable (DiagnosticEvent) -> Void = { _ in }) async throws -> LumeProbeResponse {
            let text = command == .version ? "0.5.3" : "--unattended Tahoe --detach --display native" + (storageAdvertised ? " --storage" : "")
            let launch = try await owner.withLumeLaunchIntent(command: command) { intent in
                var invocation = ProcessInvocation(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", text])
                invocation.capturing = [.stdout]; invocation.maximumOutputBytes = truncate ? 2 : 1 << 20
                invocation.observation = .forkHistory; invocation.timeout = .seconds(5)
                let run = try await ProcessRunner().run(invocation, runID: intent.attemptID)
                try await self.owner.attachOwnedLumeChild(run.ownedChild, to: intent)
                return LumeProbeLaunch(intent: intent, run: run)
            }
            return try await owner.inspectLumeProbeResponse(launch, diagnostic: diagnostic)
        }
        func unsignedBundle() throws {
            let app = try LumeBundle.expectedLocation(in: storage)
            try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let metadata = ["CFBundleIdentifier": LumePin.bundleIdentifier,
                "CFBundleShortVersionString": LumePin.version.description, "CFBundleExecutable": LumePin.executableName]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: app.appending(path: "Contents/Info.plist"))
            let file = app.appending(path: "Contents/MacOS/lume")
            try Data("unsigned non-provider fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
    }

    @Test func fixedOrderUsesActualCompletionBeforeEachNextStep() async throws {
        let f = try await Fixture(), calls = Mutex<[LumeLaunchIntent.Command]>([]), log = Mutex(DiagnosticLog())
        let result = try await LumeProbeSequence.run { command in
            // Actual prior completion must have published idle before the next admission.
            #expect(try f.saved().intent == nil)
            calls.withLock { $0.append(command) }
            return try await f.step(command) { event in log.withLock { $0.append(event) } }
        }
        #expect(calls.withLock { $0 } == [.version, .createHelp, .detachedRunHelp, .attachHelp])
        #expect(result == LumeProbeResult(version: LumePin.version, unattendedTahoeAdvertised: true,
            createRunAttachStorageAdvertised: true, detachedRunAdvertised: true, nativeAttachAdvertised: true))
        #expect(try f.saved().intent == nil && f.saved().child == nil)
        let events = log.withLock { $0.records.map(\.event) }
        #expect(events.map(\.outcome) == Array(repeating: [.started, .succeeded], count: 4).flatMap { $0 })
        #expect(Set(events.map(\.operationID)).count == 4 && events.allSatisfy { $0.environmentID == nil })
        await f.owner.close()
    }

    @Test(arguments: [LumeLaunchIntent.Command.createHelp, .detachedRunHelp, .attachHelp])
    func storageAdvertisementRequiresEverySurface(_ missing: LumeLaunchIntent.Command) async throws {
        let f = try await Fixture()
        let result = try await LumeProbeSequence.run { try await f.step($0, storageAdvertised: $0 != missing) }
        #expect(!result.createRunAttachStorageAdvertised)
        #expect(result.unattendedTahoeAdvertised && result.detachedRunAdvertised && result.nativeAttachAdvertised)
        await f.owner.close()
    }

    @Test(arguments: LumeLaunchIntent.Command.allCases)
    func actualFailedStepStopsTheSequenceAndRetainsItsIntent(_ failing: LumeLaunchIntent.Command) async throws {
        let f = try await Fixture(), calls = Mutex<[LumeLaunchIntent.Command]>([])
        await #expect(throws: LumeProbeResponseFailure.invalidResponse) {
            _ = try await LumeProbeSequence.run { command in
                calls.withLock { $0.append(command) }
                return try await f.step(command, truncate: command == failing)
            }
        }
        let expected = Array(LumeLaunchIntent.Command.allCases.prefix(through: try #require(LumeLaunchIntent.Command.allCases.firstIndex(of: failing))))
        #expect(calls.withLock { $0 } == expected)
        #expect(try f.saved().intent?.command == failing)
        let before = try Data(contentsOf: f.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await f.owner.probeLume() }
        #expect(try Data(contentsOf: f.record) == before)
        await f.owner.close()
    }

    @Test(arguments: LumeLaunchIntent.Command.allCases)
    func responseKindMismatchCannotAdvanceOrPublishAggregate(_ mismatch: LumeLaunchIntent.Command) async throws {
        let calls = Mutex<[LumeLaunchIntent.Command]>([])
        // Pure typed data tests sequencer binding, never verification or settlement proof.
        await #expect(throws: LumeProbeResponseFailure.invalidResponse) {
            _ = try await LumeProbeSequence.run { command in
                calls.withLock { $0.append(command) }
                if command == mismatch { return command == .version ? .attachHelp(nativeDisplayAdvertised: true, storageAdvertised: true) : .version(LumePin.version) }
                switch command {
                case .version: return .version(LumePin.version)
                case .createHelp: return .createHelp(unattendedTahoeAdvertised: true, storageAdvertised: true)
                case .detachedRunHelp: return .detachedRunHelp(detachAdvertised: true, storageAdvertised: true)
                case .attachHelp: return .attachHelp(nativeDisplayAdvertised: true, storageAdvertised: true)
                }
            }
        }
        #expect(calls.withLock { $0.last } == mismatch)
    }

    @Test func wrongTypedVersionStopsBeforeHelp() async throws {
        let calls = Mutex(0)
        await #expect(throws: LumeProbeResponseFailure.versionMismatch) {
            _ = try await LumeProbeSequence.run { _ in calls.withLock { $0 += 1 }; return .version(SemanticVersion([0, 6, 0])) }
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(arguments: [LumeLaunchIntent.Command.version, .attachHelp])
    func cancellationAfterRealCompletionNeverReturnsAnAggregate(_ cancelAfter: LumeLaunchIntent.Command) async throws {
        let f = try await Fixture(), calls = Mutex<[LumeLaunchIntent.Command]>([])
        let task = Task {
            try await LumeProbeSequence.run { command in
                calls.withLock { $0.append(command) }
                let value = try await f.step(command)
                if command == cancelAfter { withUnsafeCurrentTask { $0?.cancel() } }
                return value
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(calls.withLock { $0.last } == cancelAfter)
        // These preceding steps genuinely settled; cancellation creates no next intent.
        #expect(try f.saved().intent == nil && f.saved().child == nil)
        await f.owner.close()
    }

    @Test(arguments: ["configuration", "bundle", "unsigned"])
    func productionEntryRefusesBeforeAnyCandidateEffect(_ missing: String) async throws {
        let f = try await Fixture(), before = try Data(contentsOf: f.record), log = Mutex(DiagnosticLog())
        if missing != "configuration" { try await f.owner.prepareLumeProbeConfiguration() }
        if missing == "unsigned" { try f.unsignedBundle() }
        await #expect(throws: (any Error).self) {
            _ = try await f.owner.probeLume { event in log.withLock { $0.append(event) } }
        }
        #expect(try Data(contentsOf: f.record) == before)
        #expect(log.withLock { $0.records.isEmpty }) // No fabricated runtime operation ID on precheck refusal.
        if missing == "configuration" { #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "state/lume-xdg").path)) }
        await f.owner.close()
    }

    @Test(arguments: [false, true])
    func queuedWholeProbeRechecksClosureAndCancellation(_ cancel: Bool) async throws {
        let f = try await Fixture(), before = try Data(contentsOf: f.record)
        let (entered, signal) = AsyncStream<Void>.makeStream(), (queued, queue) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); queue.finish(); resume.finish() }
        let coordinator = LumeRuntimeCoordinator { queue.yield(()) }
        let holder = Task { try await coordinator.withExclusiveAccess(for: f.storage) {
            signal.yield(()); for await _ in release { break }
        } }
        var arrivals = entered.makeAsyncIterator(), waits = queued.makeAsyncIterator()
        _ = await arrivals.next()
        let probe = Task { try await f.owner.probeLume(coordinator: coordinator) }
        _ = await waits.next()
        if cancel { probe.cancel() }
        else { await f.owner.close() }
        resume.yield(()); try await holder.value
        if cancel { await #expect(throws: CancellationError.self) { _ = try await probe.value } }
        else { await #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) { _ = try await probe.value } }
        #expect(try Data(contentsOf: f.record) == before)
        await f.owner.close()
    }

    @Test func physicalRootLeaseSpansEvenTheIdleGapBetweenRealSteps() async throws {
        let f = try await Fixture(), enteredReplacement = Mutex(false), calls = Mutex<[LumeLaunchIntent.Command]>([])
        let alias = f.base.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.base)
        let aliasStorage = try RuntimeStorage(existingRoot: alias.appending(path: "Guesthouse"))
        let (entered, signal) = AsyncStream<Void>.makeStream(), (release, resume) = AsyncStream<Void>.makeStream()
        let (waiting, arrival) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); resume.finish(); arrival.finish() }
        let coordinator = LumeRuntimeCoordinator { arrival.yield(()) }
        let probe = Task {
            // The policy's private test coordinator is separate from Fixture.step's normal
            // StateStore leases. Production supplies the already-owned private step methods.
            try await LumeProbeSequence.run(in: f.storage, coordinator: coordinator) { command in
                #expect(!enteredReplacement.withLock { $0 })
                calls.withLock { $0.append(command) }
                let value = try await f.step(command)
                if command == .version {
                    #expect(try f.saved().intent == nil) // Actual inspected idle, not guessed exit.
                    signal.yield(()); for await _ in release { break }
                }
                return value
            }
        }
        var arrivals = entered.makeAsyncIterator(), waits = waiting.makeAsyncIterator()
        _ = await arrivals.next()
        let replacement = Task { try await coordinator.withExclusiveAccess(for: aliasStorage) {
            enteredReplacement.withLock { $0 = true }
            arrival.yield(()) // Also wakes the test if a broken policy admitted it too early.
        } }
        _ = await waits.next()
        #expect(!enteredReplacement.withLock { $0 })
        resume.yield(())
        _ = try await probe.value; try await replacement.value
        #expect(calls.withLock { $0 } == LumeLaunchIntent.Command.allCases)
        #expect(enteredReplacement.withLock { $0 })
        await f.owner.close()
    }
}
