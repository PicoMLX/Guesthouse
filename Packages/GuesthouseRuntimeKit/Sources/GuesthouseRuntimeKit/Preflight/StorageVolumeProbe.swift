import Darwin
import Foundation
import GuesthouseCore

/// Runtime-only, descriptor-bound observations for #12 (MVP-PLAN.md §§2–3). UUID and
/// capacity come from one volume-attribute request, never a mount-name/container guess.
/// No path, attribute buffer or volume UUID belongs in diagnostics or the public report.
enum StorageVolumeProbe {
    struct Snapshot: Equatable, Sendable {
        let identity: UUID
        let availableBytes: UInt64
    }

    // Darwin getattrlist(2): length, returned attribute_set_t, off_t, uuid_t, aligned
    // to four bytes. PACK_INVAL fixes offsets; the returned masks still determine validity.
    static let bufferSize = 48
    private static let requestedVolume = UInt32(ATTR_VOL_SPACEAVAIL)
        | UInt32(ATTR_VOL_UUID) | UInt32(ATTR_VOL_INFO)

    /// Borrows an open directory; the caller owns its lifetime, selection and path checks.
    static func snapshot(descriptor: Int32) throws(HostProbeError) -> Snapshot {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .volumeUnavailable }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw .notADirectory }
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        request.volattr = requestedVolume
        var data = Data(count: bufferSize)
        let result = data.withUnsafeMutableBytes {
            fgetattrlist(descriptor, &request, $0.baseAddress, $0.count,
                UInt32(FSOPT_PACK_INVAL_ATTRS | FSOPT_REPORT_FULLSIZE))
        }
        guard result == 0 else { throw .volumeUnavailable }
        return try decode(data)
    }

    static func decode(_ data: Data) throws(HostProbeError) -> Snapshot {
        guard data.count == bufferSize else { throw .volumeUnavailable }
        let fields = data.withUnsafeBytes { bytes in
            (bytes.loadUnaligned(as: UInt32.self),
             bytes.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self),
             bytes.loadUnaligned(fromByteOffset: 24, as: Int64.self),
             bytes.loadUnaligned(fromByteOffset: 32, as: uuid_t.self))
        }
        let (length, returned, capacity, identifier) = fields
        guard length == UInt32(bufferSize),
              returned.commonattr == UInt32(ATTR_CMN_RETURNED_ATTRS),
              returned.volattr & ~requestedVolume == 0,
              returned.dirattr == 0, returned.fileattr == 0, returned.forkattr == 0,
              returned.volattr & UInt32(ATTR_VOL_UUID) != 0 else { throw .volumeUnavailable }
        let identity = UUID(uuid: identifier)
        guard identity != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw .volumeUnavailable
        }
        guard returned.volattr & UInt32(ATTR_VOL_SPACEAVAIL) != 0, capacity >= 0 else {
            throw .capacityUnavailable
        }
        // Actual nonprivileged free bytes; deliberately excludes optimistic purgeable-space
        // estimates. Zero is an observation. Missing/negative capacity is not zero or infinity.
        return Snapshot(identity: identity, availableBytes: UInt64(capacity))
    }
}
