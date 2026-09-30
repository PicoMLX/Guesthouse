import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct XcodeBundleMetadataTests {
    @Test func readsOnlyTheBorrowedBundleAndRetainsTheCallersDescriptor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let descriptor = try fixture.pin()
        defer { close(descriptor) }
        let moved = fixture.base.appending(path: "Moved.app")
        try FileManager.default.moveItem(at: fixture.bundle, to: moved)
        try FileManager.default.createDirectory(at: fixture.bundle, withIntermediateDirectories: false)
        let result = try XcodeBundleInspection.candidate(borrowing: descriptor)
        #expect(result.version == SemanticVersion("26.6"))
        #expect(result.build == "17F113")
        #expect(result.sizeEstimateBytes != nil)
        #expect(fcntl(descriptor, F_GETFD) >= 0)
    }

    @Test(arguments: ["identifier", "package", "version", "build", "program", "programPath", "programMode", "contentsLink", "plistLink", "programLink", "fifo", "oversize", "malformed", "directory"])
    func rejectsWrongIncompleteOrEscapingBundles(kind: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var expected = XcodeSelectionFailure.metadataUnreadable
        var metadata = Fixture.metadata
        switch kind {
        case "identifier": metadata["CFBundleIdentifier"] = "example.other"; expected = .notXcode
        case "package": metadata["CFBundlePackageType"] = "BNDL"; expected = .notAnApplication
        case "version": metadata["CFBundleShortVersionString"] = "26\n.6"
        case "build": metadata["DTXcodeBuild"] = "secret=value"
        case "program": try FileManager.default.removeItem(at: fixture.program); expected = .notAnApplication
        case "programPath": metadata["CFBundleExecutable"] = "../Xcode"; expected = .notAnApplication
        case "programMode": try #require(chmod(fixture.program.path, 0o600) == 0); expected = .notAnApplication
        default: break
        }
        try fixture.write(metadata)
        let target = kind == "contentsLink" ? fixture.bundle.appending(path: "Contents") : kind == "programLink" ? fixture.program : fixture.info
        if ["contentsLink", "plistLink", "programLink"].contains(kind) {
            let outside = fixture.base.appending(path: "outside")
            try FileManager.default.moveItem(at: target, to: outside)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        }
        if kind == "fifo" {
            try FileManager.default.removeItem(at: fixture.info)
            try #require(mkfifo(fixture.info.path, 0o600) == 0)
        }
        if kind == "oversize" {
            let file = try FileHandle(forWritingTo: fixture.info)
            defer { try? file.close() }
            try file.truncate(atOffset: UInt64(XcodeBundleMetadata.maximumMetadataBytes + 1))
        }
        if kind == "malformed" { try Data("not a plist".utf8).write(to: fixture.info) }
        if kind == "directory" {
            try FileManager.default.removeItem(at: fixture.info)
            try FileManager.default.createDirectory(at: fixture.info, withIntermediateDirectories: false)
        }
        let descriptor = try fixture.pin()
        defer { close(descriptor) }
        #expect(throws: expected) { try XcodeBundleMetadata.candidate(borrowing: descriptor) }
    }

    @Test func versionPlistBuildTakesPrecedenceAndInvalidPresentMetadataIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let versions = fixture.bundle.appending(path: "Contents/version.plist")
        try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": "17F114"], format: .binary, options: 0).write(to: versions)
        let descriptor = try fixture.pin()
        defer { close(descriptor) }
        #expect(try XcodeBundleMetadata.candidate(borrowing: descriptor).build == "17F114")
        try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": 17], format: .binary, options: 0).write(to: versions)
        #expect(throws: XcodeSelectionFailure.metadataUnreadable) { try XcodeBundleMetadata.candidate(borrowing: descriptor) }
        try Data("damaged".utf8).write(to: versions)
        #expect(throws: XcodeSelectionFailure.metadataUnreadable) { try XcodeBundleMetadata.candidate(borrowing: descriptor) }
    }

    @Test func regularFileAndInvalidDescriptorCannotBecomeCandidates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = open(fixture.info.path, O_RDONLY | O_CLOEXEC)
        try #require(file >= 0)
        defer { close(file) }
        #expect(throws: XcodeSelectionFailure.notAnApplication) { try XcodeBundleMetadata.candidate(borrowing: file) }
        #expect(throws: XcodeSelectionFailure.unavailable) { try XcodeBundleMetadata.candidate(borrowing: -1) }
    }

    private struct Fixture {
        let base: URL
        var bundle: URL { base.appending(path: "Xcode.app") }
        var info: URL { bundle.appending(path: "Contents/Info.plist") }
        var program: URL { bundle.appending(path: "Contents/MacOS/Xcode") }
        static var metadata: [String: String] {
            ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "26.6",
             "DTXcodeBuild": "17F113", "CFBundleExecutable": "Xcode"]
        }
        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-xcode-\(UUID())")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: bundle.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try write(Self.metadata)
            try Data("fixture only; never executed".utf8).write(to: program)
            try #require(chmod(program.path, 0o700) == 0)
        }
        func pin() throws -> Int32 {
            let descriptor = open(bundle.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try #require(descriptor >= 0)
            return descriptor
        }
        func write(_ metadata: [String: String]) throws {
            try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: info)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
