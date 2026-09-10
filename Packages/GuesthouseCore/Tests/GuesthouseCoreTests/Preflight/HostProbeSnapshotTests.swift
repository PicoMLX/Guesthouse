import Foundation
import Testing
@testable import GuesthouseCore

struct HostProbeSnapshotTests {
    @Test func defaultsRepresentMissingEvidenceRatherThanAHealthyHost() throws {
        let snapshot = HostProbeSnapshot()
        #expect(snapshot.cpuArchitecture == .unknown)
        #expect(snapshot.operatingSystemVersion == nil)
        #expect(snapshot.physicalMemoryBytes == nil)
        #expect(snapshot.powerSource == .unknown)
        #expect(snapshot.disk == .unavailable(.storageRootUnknown))
        #expect(snapshot.codexDesktop == .unavailable)
        #expect(try roundTrip(snapshot) == snapshot)
    }

    @Test func observedZeroAndFullRangeMemoryRemainDistinctFromMissing() throws {
        let zero = HostProbeSnapshot(operatingSystemVersion: SemanticVersion([0]), physicalMemoryBytes: 0,
                                     disk: .available(bytes: 0), codexDesktop: .notFound)
        let full = HostProbeSnapshot(physicalMemoryBytes: .max, disk: .available(bytes: .max))
        #expect(zero != HostProbeSnapshot())
        #expect(try roundTrip(zero) == zero)
        #expect(try roundTrip(full) == full)
    }

    @Test(arguments: [CodexDesktopObservation.notFound, .unavailable,
                      .installed(version: nil, build: nil),
                      .installed(version: SemanticVersion([1, 2, 3]), build: SemanticVersion([456]))])
    func discoveryAndMetadataCasesSurviveEncoding(_ observation: CodexDesktopObservation) throws {
        let snapshot = HostProbeSnapshot(codexDesktop: observation)
        #expect(try roundTrip(snapshot).codexDesktop == observation)
    }

    @Test(arguments: [CPUArchitecture.appleSilicon, .intel, .unknown],
          [PowerSource.externalPower, .battery, .unknown])
    func typedArchitectureAndPowerAreIndependent(architecture: CPUArchitecture, power: PowerSource) throws {
        let snapshot = HostProbeSnapshot(cpuArchitecture: architecture, powerSource: power)
        #expect(try roundTrip(snapshot) == snapshot)
    }

    @Test(arguments: HostProbeError.allCases)
    func storageFailuresKeepTheirCauseAndFixedRecovery(_ failure: HostProbeError) throws {
        let snapshot = HostProbeSnapshot(disk: .unavailable(failure))
        #expect(try roundTrip(snapshot).disk == .unavailable(failure))
        #expect(!failure.userMessage.isEmpty)
        #expect(!failure.recoveryActions.isEmpty)
        #expect(failure.errorDescription == failure.userMessage)
        #expect(failure.recoverySuggestion?.isEmpty == false)
    }

    @Test func replacedVolumeOffersInspectionInsteadOfBlindRetry() {
        #expect(HostProbeError.volumeIdentityChanged.recoveryActions == [.inspectState, .cancel])
        #expect(HostProbeError.volumeUnavailable.recoveryActions.contains(.retry))
    }

    @Test func extraRawFieldsCannotBecomeSnapshotOrErrorOutput() throws {
        let snapshot = HostProbeSnapshot(cpuArchitecture: .appleSilicon, operatingSystemVersion: SemanticVersion([26, 4]),
                                         physicalMemoryBytes: 32, disk: .unavailable(.capacityUnavailable))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        let marker = "untrusted raw path / credentials / error text"
        object["storageRootPath"] = marker
        object["operatingSystemBuild"] = marker
        object["underlyingError"] = marker
        object["detail"] = marker
        let restored = try JSONDecoder().decode(HostProbeSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored == snapshot)
        #expect(!String(decoding: try JSONEncoder().encode(restored), as: UTF8.self).contains(marker))
        #expect(!HostProbeError.capacityUnavailable.userMessage.contains(marker))
    }

    @Test(arguments: ["cpuArchitecture", "powerSource"])
    func unknownScalarCasesAreRefused(field: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(HostProbeSnapshot())) as? [String: Any])
        object[field] = "future-value"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HostProbeSnapshot.self, from: data) }
    }

    @Test(arguments: ["disk", "codexDesktop"])
    func unknownObservationCasesAreRefused(field: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(HostProbeSnapshot())) as? [String: Any])
        object[field] = ["future-value": [String: String]()]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HostProbeSnapshot.self, from: data) }
    }

    @Test(arguments: ["1.2\n.3", "Bearer unrelated-text", String(repeating: "1", count: 257)])
    func rawVersionPayloadsAreNotAcceptedAsApplicationMetadata(version: String) throws {
        let object: [String: Any] = ["installed": ["version": version, "build": "456"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CodexDesktopObservation.self, from: data) }
    }

    @Test func unknownStorageFailureIsNotCollapsedIntoAnAvailableDisk() throws {
        let data = try JSONEncoder().encode("future-failure")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HostProbeError.self, from: data) }
    }

    private func roundTrip(_ snapshot: HostProbeSnapshot) throws -> HostProbeSnapshot {
        try JSONDecoder().decode(HostProbeSnapshot.self, from: JSONEncoder().encode(snapshot))
    }
}
