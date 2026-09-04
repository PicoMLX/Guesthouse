import Foundation
import GuesthouseCore
import Testing
@testable import Guesthouse

@MainActor
@Suite struct DiagnosticsTests {
    @Test func exportCarriesRedactedLinesEnvironmentIDsAndRuntimeInfoButNoAddresses() async throws {
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let operation = OperationID()
        let raw = ["remote: token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab used", "guest 192.168.64.7 answered"]
        var events: [RuntimeEvent] = [.accepted(operation)]
        events += Redactor().redact(lines: raw).map { RuntimeEvent.log(operation, $0) }
        events.append(.completed(operation))
        let backend = ScriptedBackend(events: events, environments: [environment], status: EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready, observed: ObservedTuple(tartVersion: "2.36.0")))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.runtimeInfo?.serviceVersion == "9.9")
        model.start(environment.id)
        // The start drops the status it began from — it completed without describing the
        // environment — so the export is taken once the check that follows has answered and
        // the observation the manifest reports is back.
        for _ in 0..<1200 where model.lastLogs[environment.id] == nil || model.statuses[environment.id] == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.diagnosticsLines.count == 2)
        let export = model.diagnosticsExport()
        #expect(!export.logText.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(!export.logText.contains("192.168.64.7"))
        #expect(export.logText.contains("[redacted:github-token]"))
        #expect(export.manifest.environmentIDs == [environment.id])
        #expect(export.manifest.runtime?.serviceVersion == "9.9")
        #expect(export.manifest.compatibility.tartVersion == "2.36.0")
        let manifest = String(decoding: export.files[0].contents, as: UTF8.self)
        #expect(!manifest.contains("192.168"))
    }

    @Test func fileStampsHaveNoColons() {
        #expect(!DiagnosticsView.stamp(Date(timeIntervalSince1970: 1_800_000_000)).contains(":"))
    }

    @Test func theWriterCreatesAFolderWithThreeFiles() throws {
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: nil, compatibility: ObservedTuple(), environments: [], logs: [])
        let directory = FileManager.default.temporaryDirectory.appending(path: "Diagnostics-\(UUID().uuidString)")
        try DiagnosticsExportWriter.write(export, to: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == [DiagnosticsExport.excludedFileName, DiagnosticsExport.logFileName, DiagnosticsExport.manifestFileName])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
    }

    @Test func theWriterRefusesADestinationThatHoldsAnythingElse() throws {
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: nil, compatibility: ObservedTuple(), environments: [], logs: [])
        let directory = FileManager.default.temporaryDirectory.appending(path: "Diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bystander = directory.appending(path: "id_ed25519")
        try Data("not part of the bundle".utf8).write(to: bystander)
        #expect(throws: GuesthouseError.self) { try DiagnosticsExportWriter.write(export, to: directory) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["id_ed25519"], "nothing was written beside it and nothing was removed")
    }

    @Test func aFailedWriteLeavesNoHalfBundleBehind() throws {
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: nil, compatibility: ObservedTuple(), environments: [], logs: [])
        let directory = FileManager.default.temporaryDirectory.appending(path: "Diagnostics-\(UUID().uuidString)")
        struct DiskFull: Error {}
        var written = 0
        #expect(throws: DiskFull.self) {
            try DiagnosticsExportWriter.write(export, to: directory) { contents, url in
                written += 1
                guard written < 2 else { throw DiskFull() }
                try contents.write(to: url, options: .atomic)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path), "a folder this attempt made goes with the files it wrote")
        // The retry the user makes next has to be allowed to land in the folder the save
        // panel offers again, which the emptiness guard would refuse over a leftover manifest.
        try DiagnosticsExportWriter.write(export, to: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [DiagnosticsExport.excludedFileName, DiagnosticsExport.logFileName, DiagnosticsExport.manifestFileName])
    }

    @Test func aFailedWriteIntoAFolderTheUserChoseEmptiesItAgain() throws {
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: nil, compatibility: ObservedTuple(), environments: [], logs: [])
        let directory = FileManager.default.temporaryDirectory.appending(path: "Diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        struct DiskFull: Error {}
        var written = 0
        #expect(throws: DiskFull.self) {
            try DiagnosticsExportWriter.write(export, to: directory) { contents, url in
                written += 1
                guard written < 3 else { throw DiskFull() }
                try contents.write(to: url, options: .atomic)
            }
        }
        #expect(FileManager.default.fileExists(atPath: directory.path), "the folder was the user's, so it stays")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "but the two files this attempt wrote do not")
    }

    @Test func theWriterTightensAnExistingEmptyDestination() throws {
        let export = DiagnosticsExportBuilder.build(appVersion: "1", appBuild: "1", runtime: nil, compatibility: ObservedTuple(), environments: [], logs: [])
        let directory = FileManager.default.temporaryDirectory.appending(path: "Diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try DiagnosticsExportWriter.write(export, to: directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700, "a folder the panel already made is protected like a new one")
    }

    @Test func theExportedLogCoversOnlyTheEnvironmentTheManifestNames() async throws {
        let first = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DevelopmentEnvironment(name: "Spare Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_100))
        let operation = OperationID()
        var events: [RuntimeEvent] = [.accepted(operation)]
        events += Redactor().redact(lines: ["Booting virtual machine"]).map { RuntimeEvent.log(operation, $0) }
        events.append(.completed(operation))
        let backend = ScriptedBackend(events: events, environments: [first, second], status: EnvironmentStatus(environmentID: first.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        for environment in [first, second] {
            model.start(environment.id)
            // The check that follows an operation blocks every start while it runs, so the
            // second environment is started only once the first one has settled.
            for _ in 0..<400 where model.lastLogs[environment.id] == nil
                || !model.operations.isEmpty || !model.reconciling.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(model.diagnosticsLines.count == 2, "the sheet still shows both")
        let export = model.diagnosticsExport()
        #expect(export.manifest.environmentIDs == [first.id])
        #expect(export.logText.contains(first.id.uuid.uuidString))
        #expect(!export.logText.contains(second.id.uuid.uuidString), "an undeclared environment is not described by the bundle")
        // Diagnostics opened from the second card is a report about the second development
        // Mac, so that is the one the bundle and the sheet describe.
        #expect(model.diagnosticsLines(subject: second.id).count == 1)
        let spare = model.diagnosticsExport(subject: second.id)
        #expect(spare.manifest.environmentIDs == [second.id])
        #expect(spare.logText.contains(second.id.uuid.uuidString))
        #expect(!spare.logText.contains(first.id.uuid.uuidString))
    }

    @Test func aLostConnectionIsTheLaunchFailureTheExportReports() async throws {
        let backend = FakeRuntimeBackend()
        await backend.script("listEnvironments", .disconnect())
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        guard case .interrupted(let interruption) = model.launchState else { Issue.record("expected interrupted, got \(model.launchState)"); return }
        let failure = try #require(model.diagnosticsExport().manifest.launchFailure)
        #expect(failure.message == interruption.userMessage)
        #expect(failure.recovery == interruption.recoveryMessage)
        #expect(!failure.recoveryActions.isEmpty)
    }

    @Test func theFailureTheCardIsShowingIsInTheExport() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        model.start(environment.id)
        for _ in 0..<400 where model.lastErrors[environment.id] == nil { try await Task.sleep(for: .milliseconds(5)) }
        let failure = try #require(model.diagnosticsExport().manifest.operationFailure)
        #expect(failure.message == GuesthouseError.guestNotReachable(environment.id).userMessage)
        #expect(!failure.recoveryActions.isEmpty, "the bundle names what the user was offered")
    }

    @Test func theOperationsOwnFailureIsExportedEvenWhenItsCheckFailedToo() async throws {
        let backend = FakeRuntimeBackend()
        let environment = DevelopmentEnvironment(name: "Dev Mac", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        await backend.setEnvironments([environment])
        await backend.setStatus(EnvironmentStatus(environmentID: environment.id, vm: .stopped, readiness: .ready))
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        await backend.script("startEnvironment", .fail(error: .guestNotReachable(environment.id)))
        // The check that follows a failed start is where the state is read back, and it is
        // allowed to fail: what the card then shows is the check's failure, not the start's.
        await backend.script("environmentStatus", .fail(error: .runtimeStarting))
        model.start(environment.id)
        for _ in 0..<400 where model.lastErrors[environment.id] != .runtimeStarting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.lastErrors[environment.id] == .runtimeStarting, "the card is showing the failed check")
        let failure = try #require(model.diagnosticsExport().manifest.operationFailure)
        #expect(failure.message == GuesthouseError.guestNotReachable(environment.id).userMessage, "the bundle names the start the user is reporting")
        #expect(!failure.recoveryActions.isEmpty, "with the start's own recovery actions")
    }

    @Test func aVersionLookupThatFailsClearsTheMetadataTheExportWouldReport() async throws {
        let backend = FakeRuntimeBackend()
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.runtimeInfo != nil, "the first check published the runtime it found")
        await backend.script("runtimeVersion", .fail(error: .protocolMismatch(client: 2, service: 1)))
        await model.refresh()
        #expect(model.launchState == .unavailable(.protocolMismatch(client: 2, service: 1)))
        #expect(model.runtimeInfo == nil, "no current metadata means none is exported")
        #expect(model.diagnosticsExport().manifest.runtime == nil)
    }

    @Test func aLostReconciliationReportsWhatItReadRatherThanTheLastSession() async throws {
        let backend = FakeRuntimeBackend()
        let model = AppModel(backend: backend) { _ in }
        await model.refresh()
        #expect(model.runtimeInfo != nil, "the first check published the runtime it found")
        // The connection drops before the runtime describes itself. The version the previous
        // session gave is not evidence about this one, and the export must not put it beside
        // the connection failure.
        await backend.script("runtimeVersion", .disconnect())
        await model.refresh()
        guard case .interrupted = model.launchState else { Issue.record("expected interrupted, got \(model.launchState)"); return }
        #expect(model.runtimeInfo == nil, "nothing verified a runtime this time")
        #expect(model.diagnosticsExport().manifest.runtime == nil)
        // A refresh that did read the version before losing the listing reports that reading:
        // it is the current one, and discarding it would keep the export empty for no reason.
        await backend.script("runtimeVersion", .succeed())
        await backend.setVersionInfo(RuntimeVersionInfo(serviceVersion: "9.9", serviceBuild: "fake", tart: .init(version: "2.37.1", verified: true)))
        await backend.script("listEnvironments", .disconnect())
        await model.refresh()
        guard case .interrupted = model.launchState else { Issue.record("expected interrupted, got \(model.launchState)"); return }
        #expect(model.runtimeInfo?.serviceVersion == "9.9")
        #expect(model.diagnosticsExport().manifest.runtime?.tart?.version == "2.37.1")
    }
}
