import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct XcodeImportValidatorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "XcodeImportValidatorTests-\(UUID().uuidString)")

    // The fixture folder is `0700` explicitly: continuous integration runs with a permissive
    // umask, and a folder other users can change is not one to build fixtures in.
    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }

    func bundle(name: String = "Xcode.app", identifier: String = XcodeImportValidator.xcodeBundleIdentifier, version: String = "26.6", build: String? = "17F113") throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Xcode"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appending(path: "Contents/Info.plist"))
        if let build {
            try PropertyListSerialization.data(fromPropertyList: ["ProductBuildVersion": build], format: .xml, options: 0).write(to: url.appending(path: "Contents/version.plist"))
        }
        // Written executable, the way an installed application is: the validator refuses a
        // wrapper whose declared program is missing or is not a program.
        try Data(repeating: 1, count: 4096).write(to: url.appending(path: "Contents/MacOS/Xcode"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appending(path: "Contents/MacOS/Xcode").path)
        return url
    }

    /// Opens a bundle the way the validator does, so a test can measure or read through the
    /// descriptor that pins it.
    func pin(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        return descriptor
    }

    @Test func metadataThatSanitizesToNothingIsRefused() throws {
        let app = try bundle(name: "Blank.app", version: "\u{200B}\u{200B}")
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: app) }
    }

    @Test func anUnreadableEntryMakesTheEstimateUnknown() throws {
        let app = try bundle(name: "Unreadable.app")
        let hidden = app.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: hidden.appending(path: "file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path) }
        let bundle = try pin(app)
        defer { close(bundle) }
        #expect(XcodeImportValidator.estimateSize(ofBundle: bundle) == nil, "a partial sum is not an estimate")
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
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.unresolvable)) {
            try XcodeImportValidator.resolve(FileHandoff(kind: .securityScopedBookmark(bookmark), displayName: "Marked.app"))
        }
        let resolved = try XcodeImportValidator.resolve(FileHandoff(kind: .securityScopedBookmark(bookmark), displayName: "Marked.app"), requireSecurityScope: false)
        #expect(resolved.url.standardizedFileURL.path == url.standardizedFileURL.path)
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.unresolvable)) {
            try XcodeImportValidator.resolve(FileHandoff(kind: .securityScopedBookmark(Data([1, 2, 3])), displayName: "x.app"), requireSecurityScope: false)
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
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: noBuild) }
        let damaged = try bundle(name: "Damaged.app")
        try Data("not a property list".utf8).write(to: damaged.appending(path: "Contents/Info.plist"))
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: damaged) }
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
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: linked) }
        let deep = root.appending(path: "deep")
        for index in 0..<40 { try FileManager.default.createDirectory(at: deep.appending(path: "d\(index)"), withIntermediateDirectories: true) }
        let deepDescriptor = try pin(deep)
        defer { close(deepDescriptor) }
        #expect(XcodeImportValidator.estimateSize(ofBundle: deepDescriptor) == 0, "directories count as entries but add no bytes")
    }

    @Test func metadataReachedThroughALinkedAncestorIsRefused() throws {
        let real = try bundle(name: "Real.app")
        let wrapper = root.appending(path: "Wrapper.app")
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: wrapper.appending(path: "Contents"), withDestinationURL: real.appending(path: "Contents"))
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: wrapper) }
    }

    @Test func anAncestorReplacedAfterTheCheckIsNotFollowed() throws {
        // The walk goes down from the bundle directory one component at a time and never
        // follows a link, so a `Contents` swapped for a link to somewhere else is refused
        // even though the bundle itself passed the containment check.
        let real = try bundle(name: "Genuine.app")
        let elsewhere = try bundle(name: "Elsewhere.app")
        try FileManager.default.removeItem(at: real.appending(path: "Contents"))
        try FileManager.default.createSymbolicLink(at: real.appending(path: "Contents"), withDestinationURL: elsewhere.appending(path: "Contents"))
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: real) }
    }

    @Test func metadataTheRedactorChangesIsRefused() throws {
        // "2\n6.6" sanitizes to "26.6": a version no bundle declared. Reporting it would be a
        // fabricated success, so altered metadata is refused instead.
        let spliced = try bundle(name: "Spliced.app", version: "2\n6.6")
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: spliced) }
        let overridden = try bundle(name: "Overridden.app", build: "17F1\u{202E}13")
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: overridden) }
    }

    @Test func aNamedPipeWhereMetadataBelongsIsRefusedNotWaitedOn() throws {
        let app = try bundle(name: "Pipe.app")
        let info = app.appending(path: "Contents/Info.plist")
        try FileManager.default.removeItem(at: info)
        #expect(mkfifo(info.path, 0o600) == 0)
        // Without a nonblocking open this waits for a writer that never comes, and the request
        // — and its session slot — never come back.
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.metadataUnreadable)) { try XcodeImportValidator.candidate(at: app) }
    }

    @Test func metadataIsReadThroughTheDescriptorThatPinsTheBundle() throws {
        let real = try bundle(name: "Pinned.app")
        let descriptor = open(real.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        // The selected bundle is renamed away and something else takes its name, which is what
        // a bundle in a user-writable place allows between one metadata read and the next.
        try FileManager.default.moveItem(at: real, to: root.appending(path: "Moved.app"))
        _ = try bundle(name: "Pinned.app", identifier: "com.example.NotXcode")
        let info = try XcodeImportValidator.plist(["Contents", "Info.plist"], in: descriptor)
        #expect(info?["CFBundleIdentifier"] as? String == XcodeImportValidator.xcodeBundleIdentifier,
                "the read follows the bundle that was opened, not whatever holds its name now")
    }

    @Test func aSizeIsMeasuredThroughTheDescriptorThatPinsTheBundle() throws {
        let real = try bundle(name: "Measured.app")
        let descriptor = try pin(real)
        defer { close(descriptor) }
        #expect(XcodeImportValidator.stillNames(descriptor, at: real), "nothing moved: the path names the pinned bundle")
        let measured = try #require(XcodeImportValidator.estimateSize(ofBundle: descriptor))
        // The selected bundle is renamed away and a larger tree takes its name — and could be
        // moved back before any check on the path ran. The walk descends from the descriptor,
        // so none of that reaches the sum.
        try FileManager.default.moveItem(at: real, to: root.appending(path: "MeasuredElsewhere.app"))
        let substitute = try bundle(name: "Measured.app")
        try Data(repeating: 2, count: 512 * 1024).write(to: substitute.appending(path: "Contents/MacOS/bulk"))
        #expect(XcodeImportValidator.estimateSize(ofBundle: descriptor) == measured, "the walk follows the bundle that was opened, not whatever holds its name now")
        // A link inside the bundle is not the bundle's bytes either: its target lives where it
        // is really counted, or outside the bundle altogether.
        let linked = try bundle(name: "Linked-size.app")
        let linkedDescriptor = try pin(linked)
        defer { close(linkedDescriptor) }
        let before = try #require(XcodeImportValidator.estimateSize(ofBundle: linkedDescriptor))
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "Contents/huge"), withDestinationURL: substitute.appending(path: "Contents/MacOS/bulk"))
        #expect(XcodeImportValidator.estimateSize(ofBundle: linkedDescriptor) == before)
        // The candidate is reported beside a path the import then acts on, so a path that has
        // moved on to other content — or to nothing — describes a bundle that never existed,
        // and `candidate(at:)` refuses the selection on this answer.
        #expect(!XcodeImportValidator.stillNames(descriptor, at: real))
        #expect(!XcodeImportValidator.stillNames(descriptor, at: root.appending(path: "Absent.app")))
    }

    /// A directory ending in `.app` with a crafted `Info.plist` and `version.plist` carries
    /// everything the metadata checks look at. Without this it would be reported as importable
    /// Xcode, and the failure would only appear later as a copy of something with no program in
    /// it.
    @Test func aWrapperWithoutTheProgramItDeclaresIsNotAnApplication() throws {
        let hollow = try bundle(name: "Hollow.app")
        try FileManager.default.removeItem(at: hollow.appending(path: "Contents/MacOS/Xcode"))
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notAnApplication)) { try XcodeImportValidator.candidate(at: hollow) }

        let unexecutable = try bundle(name: "Unexecutable.app")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unexecutable.appending(path: "Contents/MacOS/Xcode").path)
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notAnApplication)) { try XcodeImportValidator.candidate(at: unexecutable) }

        let foldered = try bundle(name: "Foldered.app")
        try FileManager.default.removeItem(at: foldered.appending(path: "Contents/MacOS/Xcode"))
        try FileManager.default.createDirectory(at: foldered.appending(path: "Contents/MacOS/Xcode"), withIntermediateDirectories: true)
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notAnApplication)) { try XcodeImportValidator.candidate(at: foldered) }

        // The declared name comes out of the selection's own property list: one shaped like a
        // path must not walk anywhere `Contents/MacOS` does not lead.
        let escaping = try bundle(name: "Escaping.app")
        let plist = escaping.appending(path: "Contents/Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: try Data(contentsOf: plist), format: nil) as? [String: Any])
        info["CFBundleExecutable"] = "../../../../usr/bin/true"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notAnApplication)) { try XcodeImportValidator.candidate(at: escaping) }
        let escapingDescriptor = try pin(escaping)
        defer { close(escapingDescriptor) }
        #expect(!XcodeImportValidator.hasExecutable(named: "", in: escapingDescriptor))
        #expect(!XcodeImportValidator.hasExecutable(named: "..", in: escapingDescriptor))
        #expect(XcodeImportValidator.hasExecutable(named: "Xcode", in: escapingDescriptor), "the program itself is still there; only the name it declared was not")
    }

    @Test(arguments: ["Xcode\u{0}missing", "Xcode\u{0}"])
    func aDeclaredExecutableContainingNULIsNotAnApplication(executable: String) throws {
        let app = try bundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = app.appending(path: "Contents/Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: try Data(contentsOf: plist), format: nil) as? [String: Any])
        info["CFBundleExecutable"] = executable
        // A binary plist preserves NULs. The valid `Xcode` fixture remains on disk, so a C
        // path truncated at the NUL would incorrectly make this malformed declaration pass.
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        let decoded = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        try #require(decoded["CFBundleExecutable"] as? String == executable)
        try data.write(to: plist)

        #expect(throws: GuesthouseError.xcodeSelectionRejected(.notAnApplication)) {
            try XcodeImportValidator.candidate(at: app)
        }
    }

    @Test func metadataThatOutgrowsItsSizeCheckIsRefused() throws {
        // `fstat` reports a snapshot: a metadata file inside a user-writable bundle can grow
        // before it is read, or be appended to for as long as anyone reads it.
        let oversized = root.appending(path: "oversized.plist")
        try Data(repeating: 0x41, count: XcodeImportValidator.maximumMetadataBytes + 1).write(to: oversized)
        let big = open(oversized.path, O_RDONLY | O_CLOEXEC)
        #expect(big >= 0)
        defer { close(big) }
        #expect(XcodeImportValidator.readMetadata(big) == nil)
        let small = root.appending(path: "small.plist")
        try Data("hello".utf8).write(to: small)
        let ordinary = open(small.path, O_RDONLY | O_CLOEXEC)
        #expect(ordinary >= 0)
        defer { close(ordinary) }
        #expect(XcodeImportValidator.readMetadata(ordinary) == Data("hello".utf8))
    }

    @Test func anEstimateWithoutAnAllocatedSizeOrThatDoesNotFitIsUnknown() {
        #expect(XcodeImportValidator.accumulate(4096, into: 0) == 4096)
        #expect(XcodeImportValidator.accumulate(nil, into: 8) == nil, "a volume that reports no allocated size is not a file of zero bytes")
        #expect(XcodeImportValidator.accumulate(-1, into: 8) == nil)
        #expect(XcodeImportValidator.accumulate(1, into: UInt64.max) == nil, "many links to one huge file must not overflow the total")
        #expect(XcodeImportValidator.accumulate(0, into: UInt64.max) == UInt64.max)
    }

    @Test func aCanceledScanStopsWalkingTheTree() async throws {
        let app = try bundle(name: "Canceled.app")
        let bundle = try pin(app)
        defer { close(bundle) }
        let scan = Task<UInt64?, Never> {
            // The scan begins only once the task has been cancelled, which is the state a
            // session that ended leaves its work in.
            while !Task.isCancelled { await Task.yield() }
            return XcodeImportValidator.estimateSize(ofBundle: bundle)
        }
        scan.cancel()
        #expect(await scan.value == nil, "a scan whose answer nobody will receive stops reading")
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
