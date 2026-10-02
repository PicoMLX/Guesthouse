import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct LumeProbeLaunchTests {
    private final class Fixture: Sendable {
        let base, root: URL
        let storage: RuntimeStorage
        let owner: StateStore
        var record: URL { root.appending(path: "state/lume-ownership.json") }
        var configuration: URL { root.appending(path: "state/lume-xdg") }
        var work: URL { root.appending(path: "vms/unpublished") }
        init() async throws {
            var template = Array("/private/tmp/guesthouse-fixed-probe-XXXXXX".utf8CString)
            base = URL(fileURLWithPath: String(cString: try #require(mkdtemp(&template))))
            root = base.appending(path: "Guesthouse")
            let root = root
            owner = try await StateStore.createFresh(root: { root })
            storage = try RuntimeStorage(existingRoot: root)
            try Data("saved work".utf8).write(to: work)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func installUnsignedFixture() throws {
            let app = try LumeBundle.expectedLocation(in: storage)
            try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let metadata = ["CFBundleIdentifier": LumePin.bundleIdentifier,
                "CFBundleShortVersionString": LumePin.version.description, "CFBundleExecutable": LumePin.executableName]
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
                .write(to: app.appending(path: "Contents/Info.plist"))
            let file = app.appending(path: "Contents/MacOS/lume")
            try Data("unsigned, non-provider fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
    }

    @Test(arguments: LumeLaunchIntent.Command.allCases)
    func optionsAreFixedBoundedAndUseOnlyProtectedStorage(_ command: LumeLaunchIntent.Command) async throws {
        let f = try await Fixture()
        try await f.owner.prepareLumeProbeConfiguration()
        // Pure options only: this URL is never executed or treated as verified authority.
        let executable = URL(fileURLWithPath: "/unused-options-fixture")
        let options = try LumeProbeInvocation.make(executable: executable, command: command, storage: f.storage)
        let expected: [LumeLaunchIntent.Command: [String]] = [
            .version: ["--version"], .createHelp: ["create", "--help"],
            .detachedRunHelp: ["run", "--detach", "--help"], .attachHelp: ["attach", "--help"],
        ]
        #expect(options.executable == executable && options.arguments == expected[command])
        #expect(options.environment == (try f.storage.environmentForLumeProbe()))
        #expect(options.environment["HOME"] == nil && options.environment["PATH"] == nil)
        #expect(options.currentDirectory == f.root.appending(path: "staging"))
        #expect(options.timeout == .seconds(5) && options.terminationGracePeriod == .seconds(1))
        #expect(options.maximumOutputBytes == 1 << 20 && options.capturing == [.stdout])
        #expect(options.observation == .forkHistory)
        if case .none = options.standardInput {} else { Issue.record("Probe input must be closed.") }
        await f.owner.close()
    }

    @Test func missingConfigurationIsNotCreatedByLaunch() async throws {
        let f = try await Fixture(), before = try Data(contentsOf: f.record)
        await #expect(throws: StorageFailure.inspectionFailed) { _ = try await f.owner.launchLumeProbe(command: .version) }
        #expect(!FileManager.default.fileExists(atPath: f.configuration.path))
        #expect(try Data(contentsOf: f.record) == before)
        #expect(try Data(contentsOf: f.work) == Data("saved work".utf8))
        await f.owner.close()
    }

    @Test(arguments: LumeLaunchIntent.Command.allCases)
    func missingAndUnsignedBundlesRefuseBeforeAnyIntent(_ command: LumeLaunchIntent.Command) async throws {
        let f = try await Fixture()
        try await f.owner.prepareLumeProbeConfiguration()
        let before = try Data(contentsOf: f.record)
        await #expect(throws: LumeVerificationError.bundleMissing) { _ = try await f.owner.launchLumeProbe(command: command) }
        try f.installUnsignedFixture()
        // Coherent pinned metadata never substitutes for the strict signature gate.
        await #expect(throws: LumeVerificationError.signatureInvalid) { _ = try await f.owner.launchLumeProbe(command: command) }
        #expect(try Data(contentsOf: f.record) == before)
        #expect(try Data(contentsOf: f.work) == Data("saved work".utf8))
        await f.owner.close()
    }

    @Test(arguments: ["", "vms", "state", "state/lume-xdg", "staging", "runtime"], [false, true])
    func writablePathDriftRefusesBeforeBundleChecksOrRepair(_ suffix: String, _ acl: Bool) async throws {
        let f = try await Fixture()
        try await f.owner.prepareLumeProbeConfiguration()
        let before = try Data(contentsOf: f.record)
        let target = suffix.isEmpty ? f.root : f.root.appending(path: suffix)
        if acl { try FixtureACL.install(.everyoneRead, at: target) }
        else { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        if suffix.isEmpty || suffix == "state" {
            await #expect(throws: StateStoreError.insecureDirectory(reason: .permissions)) {
                _ = try await f.owner.launchLumeProbe(command: .version)
            }
        } else {
            await #expect(throws: StorageFailure.protectionDrift) { _ = try await f.owner.launchLumeProbe(command: .version) }
        }
        #expect(throws: StorageFailure.protectionDrift) { try StorageProtection.verify(target) }
        #expect(try Data(contentsOf: f.record) == before)
        #expect(try Data(contentsOf: f.work) == Data("saved work".utf8))
        await f.owner.close()
    }

    @Test func pendingAndRestartedIntentsRefuseBeforeCandidateDiscovery() async throws {
        let f = try await Fixture()
        _ = try await f.owner.withLumeLaunchIntent(command: .version) { $0 }
        let before = try Data(contentsOf: f.record)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await f.owner.launchLumeProbe(command: .version) }
        await f.owner.close()
        let root = f.root
        let restarted = try await StateStore.open(storage: { try RuntimeStorage(existingRoot: root) })
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await restarted.launchLumeProbe(command: .version) }
        #expect(!FileManager.default.fileExists(atPath: f.configuration.path))
        #expect(try Data(contentsOf: f.record) == before)
        await restarted.close()
    }

    @Test func missingOwnershipRecordPreservesEvidenceAndRefuses() async throws {
        let f = try await Fixture(), retained = f.base.appending(path: "ownership-retained.json")
        let before = try Data(contentsOf: f.record)
        try FileManager.default.moveItem(at: f.record, to: retained)
        await #expect(throws: LumeLaunchOwnershipFailure.inspectionRequired) { _ = try await f.owner.launchLumeProbe(command: .version) }
        #expect(try Data(contentsOf: retained) == before)
        #expect(!FileManager.default.fileExists(atPath: f.record.path))
        await f.owner.close()
    }

    @Test func canceledOrClosedOwnersCannotLaunch() async throws {
        let f = try await Fixture(), before = try Data(contentsOf: f.record)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await f.owner.launchLumeProbe(command: .version)
        }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        await f.owner.close()
        await #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) {
            _ = try await f.owner.launchLumeProbe(command: .version)
        }
        #expect(try Data(contentsOf: f.record) == before)
    }

    @Test(arguments: ["configuration", "close", "cancel", "root"])
    func queuedLaunchRechecksItsOwnerAndWritablePaths(_ change: String) async throws {
        let f = try await Fixture()
        try await f.owner.prepareLumeProbeConfiguration()
        let before = try Data(contentsOf: f.record)
        let (entered, signal) = AsyncStream<Void>.makeStream(), (queued, queue) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); queue.finish(); resume.finish() }
        let coordinator = LumeRuntimeCoordinator { queue.yield(()) }
        let holder = Task {
            try await coordinator.withExclusiveAccess(for: f.storage) {
                signal.yield(())
                for await _ in release { break }
            }
        }
        var arrivals = entered.makeAsyncIterator(), waits = queued.makeAsyncIterator()
        _ = await arrivals.next()
        let launching = Task { try await f.owner.launchLumeProbe(command: .version, coordinator: coordinator) }
        _ = await waits.next()
        let preserved = f.base.appending(path: "preserved-root")
        if change == "configuration" { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.configuration.path) }
        else if change == "close" { await f.owner.close() }
        else if change == "root" {
            try FileManager.default.moveItem(at: f.root, to: preserved)
            _ = try RuntimeStorage(root: f.root)
        }
        else { launching.cancel() }
        resume.yield(())
        try await holder.value
        switch change {
        case "configuration": await #expect(throws: StorageFailure.protectionDrift) { _ = try await launching.value }
        case "close": await #expect(throws: StateStoreError.fileUnreadable(name: .stateDirectory)) { _ = try await launching.value }
        case "root": await #expect(throws: StorageFailure.unsafeStructure) { _ = try await launching.value }
        default: await #expect(throws: CancellationError.self) { _ = try await launching.value }
        }
        let record = change == "root" ? preserved.appending(path: "state/lume-ownership.json") : f.record
        #expect(try Data(contentsOf: record) == before)
        if change == "root" {
            #expect(try Data(contentsOf: preserved.appending(path: "vms/unpublished")) == Data("saved work".utf8))
            #expect(!FileManager.default.fileExists(atPath: f.record.path))
        }
        if change == "configuration" {
            #expect(try StorageProtection.structure(f.configuration).st_mode & 0o7777 == 0o755)
        }
        await f.owner.close()
    }
}
