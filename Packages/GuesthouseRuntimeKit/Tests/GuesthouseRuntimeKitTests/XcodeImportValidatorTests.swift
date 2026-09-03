import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct XcodeImportValidatorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "XcodeImportValidatorTests-\(UUID().uuidString)")

    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func bundle(name: String = "Xcode.app", identifier: String = XcodeImportValidator.xcodeBundleIdentifier, version: String = "26.6", build: String? = "17F113") throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Xcode"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appending(path: "Contents/Info.plist"))
        if let build {
            try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": build], format: .xml, options: 0).write(to: url.appending(path: "Contents/version.plist"))
        }
        try Data(repeating: 1, count: 4096).write(to: url.appending(path: "Contents/MacOS/Xcode"))
        return url
    }

    @Test func validBundleBecomesACandidate() throws {
        let url = try bundle()
        let candidate = try XcodeImportValidator.candidate(at: url, expectedBundleIdentifier: XcodeImportValidator.xcodeBundleIdentifier)
        #expect(candidate.version == "26.6")
        #expect(candidate.build == "17F113")
        #expect(candidate.path == url.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect((candidate.sizeEstimateBytes ?? 0) >= 4096)
    }

    @Test func bookmarksResolveAndDescriptorsAreNotYetSupported() throws {
        let url = try bundle(name: "Marked.app")
        let bookmark = try url.bookmarkData()
        let resolved = try XcodeImportValidator.resolve(FileHandoff(kind: .securityScopedBookmark(bookmark), displayName: "Marked.app"))
        #expect(resolved.url.standardizedFileURL.path == url.standardizedFileURL.path)
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.unresolvable)) {
            try XcodeImportValidator.resolve(FileHandoff(kind: .securityScopedBookmark(Data([1, 2, 3])), displayName: "x.app"))
        }
        #expect(throws: GuesthouseError.invalidRequest(.unsupportedOperation)) {
            try XcodeImportValidator.resolve(FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "x.app"))
        }
    }

    @Test func wrongIdentifierMissingBuildAndNonBundlesAreRejected() throws {
        let other = try bundle(name: "Other.app", identifier: "com.example.NotXcode")
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notXcode)) { try XcodeImportValidator.candidate(at: other) }
        let expectedMismatch = try bundle(name: "Xcode2.app")
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notXcode)) { try XcodeImportValidator.candidate(at: expectedMismatch, expectedBundleIdentifier: "com.example.Else") }
        let noBuild = try bundle(name: "NoBuild.app", build: nil)
        #expect(throws: GuesthouseError.xcodeComponentsIncomplete(missing: ["ProductBuildVersion"])) { try XcodeImportValidator.candidate(at: noBuild) }
        let file = root.appending(path: "file.app")
        try Data("x".utf8).write(to: file)
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notAnApplication)) { try XcodeImportValidator.candidate(at: file) }
        #expect(throws: GuesthouseError.self) { try XcodeImportValidator.candidate(at: root.appending(path: "missing.app")) }
    }

    @Test func oversizedOrLinkedMetadataIsRefusedAndEveryEntryCountsTowardTheCap() throws {
        let huge = try bundle(name: "Huge.app")
        let handle = try FileHandle(forWritingTo: huge.appending(path: "Contents/Info.plist"))
        try handle.seek(toOffset: UInt64(XcodeImportValidator.maximumMetadataBytes + 1))
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: huge) }
        let linked = try bundle(name: "Linked.app")
        let real = linked.appending(path: "Contents/Info.plist")
        try FileManager.default.moveItem(at: real, to: root.appending(path: "elsewhere.plist"))
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: root.appending(path: "elsewhere.plist"))
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notAnApplication)) { try XcodeImportValidator.candidate(at: linked) }
        let deep = root.appending(path: "deep")
        for index in 0..<40 { try FileManager.default.createDirectory(at: deep.appending(path: "d\(index)"), withIntermediateDirectories: true) }
        #expect(XcodeImportValidator.estimateSize(of: deep) == 0, "directories count as entries but add no bytes")
    }

    @Test func symlinksAreResolvedToTheRealBundle() throws {
        let real = try bundle(name: "Real.app")
        let link = root.appending(path: "Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let candidate = try XcodeImportValidator.candidate(at: link)
        #expect(candidate.path == real.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(throws: GuesthouseError.invalidRequest(.pathEscapesAllowedRoot)) {
            try XcodeImportValidator.candidate(at: root.appending(path: "../Real.app"))
        }
    }
}
