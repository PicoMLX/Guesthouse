import Darwin
import Foundation
import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct XcodeBundleSizeTests {
    @Test func repeatsPinnedMeasurementWithoutFollowingLinksOrConsumingBorrowedDescriptor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appending(path: "file"), outside = fixture.base.appending(path: "outside")
        try Data(repeating: 65, count: 16_384).write(to: file)
        try Data(repeating: 66, count: 32_768).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "link"), withDestinationURL: outside)
        var info = stat()
        try #require(lstat(file.path, &info) == 0)
        let descriptor = try fixture.pin()
        defer { close(descriptor) }
        let moved = fixture.base.appending(path: "moved")
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        for _ in 0..<2 {
            #expect(XcodeBundleSize.measure(borrowing: descriptor) == UInt64(info.st_blocks) * 512)
            #expect(fcntl(descriptor, F_GETFD) >= 0)
        }
    }

    @Test(arguments: ["entries", "depth", "unreadable", "fifo", "canceled"])
    func incompleteMeasurementIsUnknown(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sub = fixture.root.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data(repeating: 65, count: 4096).write(to: sub.appending(path: "file"))
        var limits = XcodeBundleSize.Limits()
        if kind == "entries" { limits.entries = 1 }
        if kind == "depth" { limits.depth = 0 }
        if kind == "unreadable" { try #require(chmod(sub.path, 0o000) == 0) }
        defer { _ = chmod(sub.path, 0o700) }
        if kind == "fifo" { try #require(mkfifo(fixture.root.appending(path: "pipe").path, 0o600) == 0) }
        let descriptor = try fixture.pin()
        defer { close(descriptor) }
        let calls = Mutex(0)
        let value = XcodeBundleSize.measure(borrowing: descriptor, limits: limits, isCanceled: {
            let count = calls.withLock { $0 += 1; return $0 }
            return kind == "canceled" && count > 2
        })
        #expect(value == nil)
    }

    @Test func overflowInvalidLimitsAndMissingDescriptorCannotProduceASmallEstimate() throws {
        #expect(XcodeBundleSize.adding(blocks: -1, to: 0) == nil)
        #expect(XcodeBundleSize.adding(blocks: Int64.max, to: 0) == nil)
        #expect(XcodeBundleSize.adding(blocks: 1, to: UInt64.max) == nil)
        #expect(XcodeBundleSize.adding(blocks: 8, to: 10) == 4106)
        #expect(XcodeBundleSize.measure(borrowing: -1) == nil)
        let fixture = try Fixture()
        defer { fixture.remove() }
        let descriptor = try fixture.pin()
        defer { close(descriptor) }
        #expect(XcodeBundleSize.measure(borrowing: descriptor) == 0)
        #expect(XcodeBundleSize.measure(borrowing: descriptor, limits: .init(entries: 0)) == nil)
        #expect(XcodeBundleSize.measure(borrowing: descriptor, limits: .init(depth: 65)) == nil)
    }

    private struct Fixture {
        let base: URL
        var root: URL { base.appending(path: "selected") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-size-\(UUID())")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func pin() throws -> Int32 {
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try #require(descriptor >= 0)
            return descriptor
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
