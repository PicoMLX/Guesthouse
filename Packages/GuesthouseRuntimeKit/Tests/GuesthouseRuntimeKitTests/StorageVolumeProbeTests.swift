import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

struct StorageVolumeProbeTests {
    private let identity = UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))

    @Test(arguments: [Int64(0), 1, 200_000_000_000, Int64.max])
    func validNonprivilegedCapacity(_ capacity: Int64) throws {
        let result = try StorageVolumeProbe.decode(packet(capacity: capacity))
        #expect(result.identity == identity)
        #expect(result.availableBytes == UInt64(capacity))
    }

    @Test(arguments: [UInt32(0x00040010), 0x80040010])
    func infoFlagCarriesNoAdditionalBytes(_ flags: UInt32) throws {
        let data = replacing(packet(), offset: 8, with: flags)
        #expect(try StorageVolumeProbe.decode(data).availableBytes == 42)
    }

    @Test(arguments: Array(0..<48) + [49, 256])
    func refusesIncompleteOrOversizedPackets(_ count: Int) {
        var data = packet()
        data.count = count
        #expect(throws: HostProbeError.volumeUnavailable) { try StorageVolumeProbe.decode(data) }
    }

    @Test(arguments: [UInt32(0), 24, 47, 49, UInt32.max])
    func refusesIncorrectDeclaredLength(_ length: UInt32) {
        let data = replacing(packet(), offset: 0, with: length)
        #expect(throws: HostProbeError.volumeUnavailable) { try StorageVolumeProbe.decode(data) }
    }

    @Test(arguments: [
        (4, UInt32(0)), (4, 0x80000001), (8, 0), (8, 0x10), (8, 0x40011),
        (12, 1), (16, 1), (20, 1),
    ])
    func refusesMissingIdentityOrUnexpectedAttributes(_ offset: Int, _ value: UInt32) {
        let data = replacing(packet(), offset: offset, with: value)
        #expect(throws: HostProbeError.volumeUnavailable) { try StorageVolumeProbe.decode(data) }
    }

    @Test func missingCapacityIsNotAZeroObservation() {
        let data = replacing(packet(capacity: 0), offset: 8, with: UInt32(0x40000))
        #expect(throws: HostProbeError.capacityUnavailable) { try StorageVolumeProbe.decode(data) }
    }

    @Test(arguments: [Int64(-1), Int64.min])
    func negativeCapacityIsNotClamped(_ value: Int64) {
        #expect(throws: HostProbeError.capacityUnavailable) {
            try StorageVolumeProbe.decode(packet(capacity: value))
        }
    }

    @Test func zeroUUIDIsNotRetainedIdentity() {
        var data = packet()
        data.replaceSubrange(32..<48, with: repeatElement(UInt8(0), count: 16))
        #expect(throws: HostProbeError.volumeUnavailable) { try StorageVolumeProbe.decode(data) }
    }

    @Test func invalidDescriptorIsUnavailable() {
        #expect(throws: HostProbeError.volumeUnavailable) { try StorageVolumeProbe.snapshot(descriptor: -1) }
    }

    @Test func nonDirectoryDescriptorIsNotStorage() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "GuesthouseVolume-\(UUID()).file")
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor); try? FileManager.default.removeItem(at: url) }
        #expect(throws: HostProbeError.notADirectory) { try StorageVolumeProbe.snapshot(descriptor: descriptor) }
        #expect(fcntl(descriptor, F_GETFD) >= 0) // A borrowed descriptor is not consumed.
    }

    private func packet(capacity: Int64 = 42) -> Data {
        // Independent ABI fixture: length, five returned masks, off_t, UUID bytes.
        var data = Data()
        for field in [UInt32(48), 0x80000000, 0x40010, 0, 0, 0] {
            withUnsafeBytes(of: field) { data.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: capacity) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: identity.uuid) { data.append(contentsOf: $0) }
        return data
    }

    private func replacing(_ data: Data, offset: Int, with value: UInt32) -> Data {
        var result = data
        withUnsafeBytes(of: value) { result.replaceSubrange(offset..<(offset + 4), with: $0) }
        return result
    }
}
