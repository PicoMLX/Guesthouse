import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct CompatibilityHardeningTests {
    typealias Fixtures = CompatibilityEvaluatorTests
    let defaults = CompatibilityManifest.KnownIncompatibility.defaultRecoveryActions

    @Test func decodedCapabilitiesAreNormalized() throws {
        let tuple = Fixtures.tuple(capabilities: ["b", "a"])
        let encoded = String(decoding: try JSONEncoder().encode(tuple), as: UTF8.self)
        #expect(encoded.contains(#"["a","b"]"#))
        let shuffled = encoded.replacingOccurrences(of: #"["a","b"]"#, with: #"["b","a","b"]"#)
        let decoded = try JSONDecoder().decode(CompatibilityTuple.self, from: Data(shuffled.utf8))
        #expect(decoded == tuple)
        #expect(decoded.codexCLICapabilities == ["a", "b"])
        let observed = try JSONDecoder().decode(ObservedTuple.self, from: Data(shuffled.utf8))
        #expect(observed.exact == tuple)
    }

    @Test func newerManifestSchemasAreRejected() throws {
        var manifest = CompatibilityManifest(manifestVersion: 1, tested: [])
        manifest.schemaVersion = SchemaVersion(SchemaVersion.current.rawValue + 1)!
        let data = try JSONEncoder().encode(manifest)
        #expect(throws: CompatibilityManifestError.unsupportedSchema(found: manifest.schemaVersion, supported: .current)) {
            try CompatibilityManifest.decode(from: data)
        }
        // The helper is a convenience, not the only gate: a caller reaching for Codable directly
        // must not get a manifest whose extra dimensions this build would ignore.
        #expect(throws: CompatibilityManifestError.unsupportedSchema(found: manifest.schemaVersion, supported: .current)) {
            try JSONDecoder().decode(CompatibilityManifest.self, from: data)
        }
    }

    @Test func damagedManifestResourcesReportSomethingTheUserCanDo() {
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest.decode(from: Data("not a manifest".utf8))
        }
        for error: CompatibilityManifestError in [.unreadableManifest, .malformedManifest] {
            #expect(!error.userMessage.isEmpty)
            #expect(error.recoveryActions.contains(.reinstallApp))
        }
        #expect(throws: Never.self) { try CompatibilityManifest.bundled() }
    }

    @Test func testedEntriesMustDeclareTheirCapabilities() throws {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        // Sorted, so the key this test removes is always followed by a comma: an encoder that
        // happened to put it last would leave the JSON valid and the test would prove nothing.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        let stale = json.replacingOccurrences(of: #""codexCLICapabilities":["remote-app-server"],"#, with: "")
        #expect(stale != json, "the capabilities key was removed")
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest.decode(from: Data(stale.utf8))
        }
    }

    @Test func rulesWithoutAnExplanationAreRejected() throws {
        let manifest = #"{"schemaVersion":1,"manifestVersion":1,"tested":[],"incompatibilities":[{"reason":"   "}]}"#
        #expect(throws: CompatibilityManifestError.malformedManifest) {
            try CompatibilityManifest.decode(from: Data(manifest.utf8))
        }
        let cleared = try JSONDecoder().decode(CompatibilityManifest.KnownIncompatibility.self, from: Data(#"{"reason":"broken","recoveryActions":[]}"#.utf8))
        #expect(cleared.recoveryActions == defaults)
    }

    @Test func verificationTimestampsSurviveEncoding() throws {
        // Sub-second instants included on purpose: a real `Date()` has more precision than any
        // ISO 8601 form carries, and rounding it must land somewhere the encoder reproduces.
        let instants = [Date(), Date(timeIntervalSince1970: 1_800_000_000.123456)]
            + (0..<64).map { Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 0.176_666) }
        for instant in instants {
            let verification = CompatibilityManifest.Verification(verifiedAt: instant, hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
            let data = try JSONEncoder().encode(verification)
            #expect(try JSONDecoder().decode(CompatibilityManifest.Verification.self, from: data) == verification)
        }
    }

    @Test func capabilityOrderNeverDecidesWhetherARuleFires() {
        var manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        manifest.incompatibilities = [.init(codexCLICapabilities: ["apply-patch", "remote-app-server"], reason: "this capability pair deadlocks")]
        var observed = ObservedTuple(Fixtures.tuple())
        observed.codexCLICapabilities = ["remote-app-server", "apply-patch"]
        #expect(CompatibilityEvaluator.evaluate(observed: observed, manifest: manifest, history: []) == .incompatible(reason: "this capability pair deadlocks", recoveryActions: defaults))
    }

    @Test func negativeInstallationCountsAreNeverVerified() throws {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        let impossible = Fixtures.tuple(installations: -1)
        let history = [try ConnectionVerificationRecord(tuple: impossible, verifiedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: .userConfirmedWorkspaceOpened)]
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(impossible), manifest: manifest, history: history) == .needsValidation(.unknownFields([.codexCLIInstallations])))
    }

    @Test func decodedRecordsAreRevalidatedIncludingTheirEvidence() throws {
        let record = try ConnectionVerificationRecord(tuple: Fixtures.tuple(), verifiedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: .userConfirmedWorkspaceOpened)
        let data = try JSONEncoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)
        let secret = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let poisonedTuple = json.replacingOccurrences(of: #""0.50.0""#, with: #""0.50.0 \#(secret)""#)
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIVersion)) {
            try JSONDecoder().decode(ConnectionVerificationRecord.self, from: Data(poisonedTuple.utf8))
        }
        var claimed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        claimed["evidence"] = ["machineReadableStatus": ["source": "codex --version"]]
        #expect(throws: CompatibilityRecordError.implausibleEvidenceSource) {
            try JSONDecoder().decode(ConnectionVerificationRecord.self, from: JSONSerialization.data(withJSONObject: claimed))
        }
        #expect(!CompatibilityRecordError.implausibleEvidenceSource.userMessage.isEmpty)
    }

    @Test func aVersionProbeCannotNameItselfAConnectionStatus() {
        // MVP-PLAN.md §5: `codex --version` is never evidence of a desktop connection, so a
        // source the caller invents is not a supported interface however plausible it reads.
        #expect(ConnectionVerificationRecord.supportedStatusInterfaces.isEmpty)
        for source in ["codex --version", "desktop-status", "codex login status"] {
            #expect(throws: CompatibilityRecordError.implausibleEvidenceSource) {
                try ConnectionVerificationRecord(tuple: Fixtures.tuple(), verifiedAt: Date(), evidence: .machineReadableStatus(source: source))
            }
        }
    }

    @Test func fullLengthPathsAreRecordableButUnboundedOnesAreNot() throws {
        let deep = "/Users/dev/" + String(repeating: "nested/", count: 60) + "Codex.app"
        #expect(deep.unicodeScalars.count > ConnectionVerificationRecord.maximumObservationLength)
        var far = Fixtures.tuple()
        far.codexDesktopPath = deep
        far.codexCLIPath = deep + "/Contents/MacOS/codex"
        #expect(throws: Never.self) { try ConnectionVerificationRecord(tuple: far, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened) }
        var unbounded = Fixtures.tuple()
        unbounded.codexCLIPath = "/" + String(repeating: "a", count: ConnectionVerificationRecord.maximumPathLength)
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIPath)) {
            try ConnectionVerificationRecord(tuple: unbounded, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        var wordy = Fixtures.tuple()
        wordy.codexDesktopVersion = String(repeating: "1", count: ConnectionVerificationRecord.maximumObservationLength + 1)
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexDesktopVersion)) {
            try ConnectionVerificationRecord(tuple: wordy, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
    }

    @Test func aFloodOfDuplicateCapabilitiesIsRefusedRatherThanCollapsed() throws {
        // Normalizing first would turn any number of repetitions of one identifier into a
        // one-element list the count check then accepts, after doing the set work the guest
        // asked for. The list stays over the bound instead, whichever way it was set.
        let repeated = Array(repeating: "remote-app-server", count: CompatibilityTuple.maximumCapabilities + 1)
        #expect(CompatibilityTuple.normalize(repeated).count > CompatibilityTuple.maximumCapabilities)
        var assigned = Fixtures.tuple()
        assigned.codexCLICapabilities = repeated
        for tuple in [assigned, Fixtures.tuple(capabilities: repeated)] {
            #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLICapabilities)) {
                try ConnectionVerificationRecord(tuple: tuple, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
            }
        }
    }

    @Test func onlyAResolvedPathIsAnIdentity() throws {
        // MVP-PLAN.md §5 identifies the CLI by the executable the login shell resolves. A
        // relative entry in that shell's `PATH`, or a probe that answers with one on purpose,
        // names a different executable from a different working directory.
        for path in ["codex", "./codex", "../bin/codex", "/opt/homebrew/../bin/codex"] {
            var relative = Fixtures.tuple(path: path)
            #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIPath)) {
                try ConnectionVerificationRecord(tuple: relative, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
            }
            relative = Fixtures.tuple()
            relative.codexDesktopPath = path.replacingOccurrences(of: "codex", with: "Codex.app")
            #expect(throws: CompatibilityRecordError.implausibleObservation(.codexDesktopPath)) {
                try ConnectionVerificationRecord(tuple: relative, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
            }
        }
        #expect(throws: Never.self) {
            try ConnectionVerificationRecord(tuple: Fixtures.tuple(path: "/usr/local/bin/codex"), verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
    }

    @Test func aCredentialSplitByACombiningMarkIsNotRecordable() throws {
        // The mark belongs to no category the plausibility check refuses, and it hides the
        // label from the redactor, so the value would be persisted in connection history whole.
        var poisoned = Fixtures.tuple()
        poisoned.codexCLIVersion = "0.50.0 passwo\u{0301}rd=hunter2"
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIVersion)) {
            try ConnectionVerificationRecord(tuple: poisoned, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        var spaced = Fixtures.tuple()
        spaced.guestMacOSBuild = "25F84\u{2007}token=abc123"
        #expect(throws: CompatibilityRecordError.implausibleObservation(.guestMacOSBuild)) {
            try ConnectionVerificationRecord(tuple: spaced, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        // A path that carries a mark for its own sake is still recordable, unchanged.
        let accented = Fixtures.tuple(path: "/Users/jose\u{0301}/bin/codex")
        let record = try ConnectionVerificationRecord(tuple: accented, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        #expect(record.tuple.codexCLIPath == "/Users/jose\u{0301}/bin/codex")
    }

    @Test func invertedRangesAreRejectedWhenDecoding() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VersionRange.self, from: Data(#"{"minimum":"26.5","maximum":"26.4"}"#.utf8))
        }
    }

    @Test func rulesCanTargetCLIIdentityCapabilitiesAndDesktopBundle() {
        var manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        manifest.incompatibilities = [
            .init(codexCLIVersion: "0.50.0", codexCLIPath: "/usr/local/bin/codex", reason: "bottle is broken", recoveryActions: [.repair(.tools), .cancel]),
            .init(codexCLICapabilities: ["legacy-transport"], reason: "legacy transport"),
            .init(codexDesktopPath: "/Applications/Codex Beta.app", reason: "beta desktop"),
        ]
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Fixtures.tuple()), manifest: manifest, history: []) == .needsValidation(.neverConnected))
        let broken = ObservedTuple(Fixtures.tuple(path: "/usr/local/bin/codex"))
        // The rule's own actions lead; console access and work export are added back, because
        // §5 keeps them in every blocked state whatever a rule lists.
        #expect(CompatibilityEvaluator.evaluate(observed: broken, manifest: manifest, history: []) == .incompatible(reason: "bottle is broken", recoveryActions: [.repair(.tools), .cancel, .openConsole, .exportWork]))
        let legacy = ObservedTuple(Fixtures.tuple(capabilities: ["legacy-transport"]))
        #expect(CompatibilityEvaluator.evaluate(observed: legacy, manifest: manifest, history: []) == .incompatible(reason: "legacy transport", recoveryActions: defaults))
        var beta = Fixtures.tuple()
        beta.codexDesktopPath = "/Applications/Codex Beta.app"
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(beta), manifest: manifest, history: []) == .incompatible(reason: "beta desktop", recoveryActions: defaults))
    }

    @Test func implausibleObservationsAreNeverRecorded() {
        var poisoned = Fixtures.tuple()
        poisoned.codexCLIVersion = "0.50.0 ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLIVersion)) {
            try ConnectionVerificationRecord(tuple: poisoned, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        var control = Fixtures.tuple()
        control.guestMacOSBuild = "25F84\u{1B}[31m"
        #expect(throws: CompatibilityRecordError.implausibleObservation(.guestMacOSBuild)) {
            try ConnectionVerificationRecord(tuple: control, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        var capability = Fixtures.tuple(capabilities: [String(repeating: "x", count: 300)])
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLICapabilities)) {
            try ConnectionVerificationRecord(tuple: capability, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        capability.codexCLICapabilities = ["remote-app-server"]
        #expect(throws: Never.self) { try ConnectionVerificationRecord(tuple: capability, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened) }
        let error = CompatibilityRecordError.implausibleObservation(.codexCLIVersion)
        #expect(!error.userMessage.isEmpty && !error.recoveryActions.isEmpty)
    }

    @Test func manifestErrorsAreActionableAndVerifiedManifestsRoundTrip() throws {
        let error = CompatibilityManifestError.unsupportedSchema(found: SchemaVersion(9)!, supported: .current)
        #expect(error.recoveryActions.first == .reinstallApp)
        #expect(error.errorDescription == error.userMessage)
        let verification = CompatibilityManifest.Verification(verifiedAt: Date(timeIntervalSince1970: 1_800_000_000.25), hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
        let manifest = CompatibilityManifest(manifestVersion: 2, tested: [Fixtures.tested(verification: verification)])
        let data = try JSONEncoder().encode(manifest)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("2027-01-15T08:00:00Z"))
        #expect(try CompatibilityManifest.decode(from: data) == manifest)
        // A manifest authored with fractional seconds still reads, at the same precision.
        let fractional = json.replacingOccurrences(of: "2027-01-15T08:00:00Z", with: "2027-01-15T08:00:00.250Z")
        #expect(try CompatibilityManifest.decode(from: Data(fractional.utf8)) == manifest)
    }

    @Test func aMissingCLIIsAMissingPrerequisiteNotACompetingInstallation() {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        var none = ObservedTuple(Fixtures.tuple(installations: 0))
        #expect(CompatibilityEvaluator.evaluate(observed: none, manifest: manifest, history: []) == .needsValidation(.codexCLIMissing))
        none.codexCLIVersion = nil
        none.codexCLIPath = nil
        #expect(CompatibilityEvaluator.evaluate(observed: none, manifest: manifest, history: []) == .needsValidation(.codexCLIMissing))
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Fixtures.tuple(installations: 2)), manifest: manifest, history: []) == .needsValidation(.competingInstallations(count: 2)))
    }

    @Test func capabilitiesStayCanonicalWhenTheFieldIsAssigned() throws {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        var rebuilt = Fixtures.tuple()
        rebuilt.codexCLICapabilities = ["remote-app-server", "apply-patch", "apply-patch"]
        #expect(rebuilt.codexCLICapabilities == ["apply-patch", "remote-app-server"])
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try ConnectionVerificationRecord(tuple: rebuilt, verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(rebuilt), manifest: manifest, history: [record]) == .verified(recordedAt: day))
    }

    @Test func overlongCapabilityListsAreRefused() throws {
        let many = (0...CompatibilityTuple.maximumCapabilities).map { "capability-\($0)" }
        var noisy = Fixtures.tuple()
        noisy.codexCLICapabilities = many
        #expect(throws: CompatibilityRecordError.implausibleObservation(.codexCLICapabilities)) {
            try ConnectionVerificationRecord(tuple: noisy, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
        }
        let encoded = String(decoding: try JSONEncoder().encode(Fixtures.tuple()), as: UTF8.self)
        let list = many.map { "\"\($0)\"" }.joined(separator: ",")
        let flooded = encoded.replacingOccurrences(of: #"["remote-app-server"]"#, with: "[\(list)]")
        #expect(flooded != encoded, "the capability list was replaced")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CompatibilityTuple.self, from: Data(flooded.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ObservedTuple.self, from: Data(flooded.utf8)) }
    }

    @Test func unreadableHistoryReportsSomethingTheUserCanDo() throws {
        let record = try ConnectionVerificationRecord(tuple: Fixtures.tuple(), verifiedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: .userConfirmedWorkspaceOpened)
        let data = try JSONEncoder().encode([record])
        #expect(try ConnectionVerificationRecord.decodeHistory(from: data) == [record])
        let future = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":\(ConnectionVerificationRecord.currentSchema.rawValue)", with: "\"schemaVersion\":99")
        #expect(throws: CompatibilityRecordError.unsupportedSchema(found: SchemaVersion(99)!, supported: ConnectionVerificationRecord.currentSchema)) {
            try ConnectionVerificationRecord.decodeHistory(from: Data(future.utf8))
        }
        #expect(throws: CompatibilityRecordError.malformedHistory) {
            try ConnectionVerificationRecord.decodeHistory(from: Data("not history".utf8))
        }
        for error: CompatibilityRecordError in [.malformedHistory, .unsupportedSchema(found: SchemaVersion(99)!, supported: .current)] {
            #expect(!error.userMessage.isEmpty)
            #expect(!error.recoveryActions.isEmpty)
        }
    }

    @Test func aLaterTestedEntryCanCarryTheCoveringVerification() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let elsewhere = CompatibilityManifest.Verification(verifiedAt: day.addingTimeInterval(-86_400), hostMacOSVersion: SemanticVersion("26.4")!, hostMacOSBuild: "25E20", evidence: "docs/phase0/compat.md")
        let here = CompatibilityManifest.Verification(verifiedAt: day, hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
        // Both entries describe the same combination over overlapping host ranges; only the
        // second one was verified on the host being evaluated.
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested(verification: elsewhere), Fixtures.tested(verification: here)])
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Fixtures.tuple()), manifest: manifest, history: []) == .verified(recordedAt: day))
        let unverifiedFirst = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested(), Fixtures.tested(verification: here)])
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Fixtures.tuple()), manifest: unverifiedFirst, history: []) == .verified(recordedAt: day))
    }

    @Test(arguments: [false, true])
    func newestCoveringManifestVerificationWinsRegardlessOfOrder(reverseEntries: Bool) {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let older = CompatibilityManifest.Verification(verifiedAt: day, hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
        let newestCovering = CompatibilityManifest.Verification(verifiedAt: day.addingTimeInterval(3600), hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
        let otherHost = CompatibilityManifest.Verification(verifiedAt: day.addingTimeInterval(7200), hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F99", evidence: "docs/phase0/compat.md")
        let otherCLI = CompatibilityManifest.Verification(verifiedAt: day.addingTimeInterval(10800), hostMacOSVersion: SemanticVersion("26.5.2")!, hostMacOSBuild: "25F84", evidence: "docs/phase0/compat.md")
        let entries = [
            Fixtures.tested(),
            Fixtures.tested(verification: older),
            Fixtures.tested(verification: newestCovering),
            Fixtures.tested(verification: otherHost),
            Fixtures.tested(codexCLI: "0.40.0", verification: otherCLI),
        ]
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: reverseEntries ? Array(entries.reversed()) : entries)

        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(Fixtures.tuple()), manifest: manifest, history: []) == .verified(recordedAt: Date(timeIntervalSince1970: 1_800_003_600)))
    }

    @Test func negativeProtocolVersionsAreNeverVerified() throws {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        var impossible = Fixtures.tuple()
        impossible.runtimeProtocolVersion = -1
        let history = [try ConnectionVerificationRecord(tuple: impossible, verifiedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: .userConfirmedWorkspaceOpened)]
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(impossible), manifest: manifest, history: history) == .needsValidation(.unknownFields([.runtimeProtocolVersion])))
    }

    @Test func competingInstallationsAreNamedBeforeMissingFields() {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        // A probe that refuses to pick between several `which -a` candidates reports the count
        // and nothing else about the CLI.
        var ambiguous = ObservedTuple(Fixtures.tuple(installations: 3))
        ambiguous.codexCLIVersion = nil
        ambiguous.codexCLIPath = nil
        #expect(CompatibilityEvaluator.evaluate(observed: ambiguous, manifest: manifest, history: []) == .needsValidation(.competingInstallations(count: 3)))
    }

    @Test func blankObservationsAreNeverRecorded() {
        for blank in ["   ", " 25F84", "25F84 ", "\u{00A0}"] {
            var padded = Fixtures.tuple()
            padded.guestMacOSBuild = blank
            #expect(throws: CompatibilityRecordError.implausibleObservation(.guestMacOSBuild)) {
                try ConnectionVerificationRecord(tuple: padded, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened)
            }
        }
        // An interior space is part of a real bundle name and stays recordable.
        var spaced = Fixtures.tuple()
        spaced.codexDesktopPath = "/Applications/Codex Beta.app"
        #expect(throws: Never.self) { try ConnectionVerificationRecord(tuple: spaced, verifiedAt: Date(), evidence: .userConfirmedWorkspaceOpened) }
    }

    @Test func aBlockedCombinationOffersARepairByDefault() {
        #expect(defaults.contains(.repair(.tools)))
        #expect(defaults.first == .repair(.tools))
        let rule = CompatibilityManifest.KnownIncompatibility(codexCLIVersion: "0.50.0", reason: "0.50.0 cannot start the remote app-server")
        #expect(rule.recoveryActions.contains(where: { if case .repair = $0 { true } else { false } }))
    }

    @Test func aRuleCannotTakeAwayWhatEveryBlockedStateKeeps() {
        // MVP-PLAN.md §5: block the handoff, offer an idle-time repair, and preserve console
        // access, shutdown, and work export in every state. The rules are data, so a manifest
        // that lists fewer actions cannot be trusted to have meant it.
        func actions(_ named: [RecoveryAction]) -> [RecoveryAction] {
            CompatibilityManifest.KnownIncompatibility(reason: "blocked", recoveryActions: named).recoveryActions
        }
        #expect(actions([.cancel]) == [.repair(.tools), .cancel, .openConsole, .exportWork])
        #expect(actions([.openConsole, .cancel]) == [.repair(.tools), .openConsole, .cancel, .exportWork])
        #expect(actions([]) == defaults)
        // A repair the rule names itself is the repair: some combinations are not fixed by the
        // tools flow, and a second button that cannot help is worse than none.
        #expect(actions([.repair(.xcodeComponents)]) == [.repair(.xcodeComponents), .openConsole, .exportWork, .cancel])
        let decoded = try? JSONDecoder().decode(
            CompatibilityManifest.KnownIncompatibility.self,
            from: Data(#"{"reason":"blocked","recoveryActions":[{"cancel":{}}]}"#.utf8)
        )
        #expect(decoded?.recoveryActions == [.repair(.tools), .cancel, .openConsole, .exportWork])
    }

    @Test func replacedDesktopBundleIsDrift() {
        let manifest = CompatibilityManifest(manifestVersion: 1, tested: [Fixtures.tested()])
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try! ConnectionVerificationRecord(tuple: Fixtures.tuple(), verifiedAt: day, evidence: .userConfirmedWorkspaceOpened)
        var moved = Fixtures.tuple()
        moved.codexDesktopPath = "/Users/dev/Applications/Codex.app"
        #expect(CompatibilityEvaluator.evaluate(observed: ObservedTuple(moved), manifest: manifest, history: [record]) == .needsValidation(.changedSinceLastVerified([.codexDesktopPath])))
        var unknownBundle = ObservedTuple(Fixtures.tuple())
        unknownBundle.codexDesktopPath = nil
        #expect(CompatibilityEvaluator.evaluate(observed: unknownBundle, manifest: manifest, history: [record]) == .needsValidation(.unknownFields([.codexDesktopPath])))
    }
}
