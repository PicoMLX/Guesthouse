import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

struct SystemStorageProbeTests {
    @Test func unknownLocationOrUnretainedIdentityBlocks() {
        #expect(SystemStorageProbe(storageRoot: nil, expectedVolume: UUID()).observe() == .unavailable(.storageRootUnknown))
        #expect(SystemStorageProbe(storageRoot: URL(fileURLWithPath: "/"), expectedVolume: nil).observe()
            == .unavailable(.storageRootUnknown))
    }

    @Test func nativeExistingDirectoryObservationAndBorrowedLifetime() throws {
        try withFixture { root in
            let descriptor = open(root.path, O_SEARCH | O_CLOEXEC)
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            let value = try StorageVolumeProbe.snapshot(descriptor: descriptor)
            #expect(value.availableBytes <= UInt64(Int64.max))
            #expect(fcntl(descriptor, F_GETFD) >= 0)
            let reported = try #require(root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            let foundationIdentity = try #require(UUID(uuidString: reported))
            #expect(value.identity == foundationIdentity)
            let selected = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            #expect(value.identity == selected)
            let result = SystemStorageProbe(storageRoot: root, expectedVolume: selected).observe()
            guard case .available = result else { Issue.record("Expected this writable fixture's volume capacity."); return }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func missingFirstLaunchSuffixUsesOnlyTheSelectedVolumeAndCreatesNothing() throws {
        try withFixture { root in
            let selected = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            let missing = root.appending(path: "Library/Application Support/Guesthouse")
            let result = SystemStorageProbe(storageRoot: missing, expectedVolume: selected).observe()
            guard case .available = result else { Issue.record("Expected the retained writable ancestor's capacity."); return }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func differentRetainedVolumeCannotUseTheSamePathOrAncestor(_ missing: Bool) throws {
        try withFixture { root in
            let actual = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            let different = UUID()
            try #require(actual != different)
            let target = missing ? root.appending(path: "Guesthouse") : root
            #expect(SystemStorageProbe(storageRoot: target, expectedVolume: different).observe()
                == .unavailable(.volumeIdentityChanged))
        }
    }

    @Test func initialIdentitySelectionDoesNotAscendPastAMissingDirectory() throws {
        try withFixture { root in
            #expect(throws: HostProbeError.volumeUnavailable) {
                try SystemStorageProbe.identifyVolume(atExistingDirectory: root.appending(path: "not-mounted"))
            }
        }
    }

    @Test(arguments: [false, true])
    func regularFileOrFileAncestorIsRefused(_ descendant: Bool) throws {
        try withFixture { root in
            let selected = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            let file = root.appending(path: "file")
            try Data().write(to: file)
            let target = descendant ? file.appending(path: "Guesthouse") : file
            #expect(SystemStorageProbe(storageRoot: target, expectedVolume: selected).observe()
                == .unavailable(.notADirectory))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func finalOrDanglingLinkIsNotAnAncestorFallback(_ dangling: Bool, _ trailingSlash: Bool) throws {
        try withFixture { root in
            let selected = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            let link = root.appending(path: "linked")
            try FileManager.default.createSymbolicLink(at: link,
                withDestinationURL: dangling ? root.appending(path: "absent") : root)
            let target = URL(fileURLWithPath: link.path, isDirectory: trailingSlash)
            #expect(SystemStorageProbe(storageRoot: target, expectedVolume: selected).observe()
                == .unavailable(.volumeUnavailable))
        }
    }

    @Test func missingSuffixBelowDanglingLinkDoesNotMeasureStartupDisk() throws {
        try withFixture { root in
            let selected = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            let link = root.appending(path: "linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appending(path: "absent"))
            #expect(SystemStorageProbe(storageRoot: link.appending(path: "Guesthouse"), expectedVolume: selected).observe()
                == .unavailable(.volumeUnavailable))
        }
    }

    @Test(arguments: [Int32(-1), 1, Int32.min, Int32.max])
    func everyFailedWriteAccessCheckBlocks(_ result: Int32) {
        #expect(throws: HostProbeError.destinationNotWritable) { try SystemStorageProbe.requireWritable(result) }
    }

    @Test(arguments: [
        (EACCES, HostProbeError.destinationNotWritable), (EPERM, .destinationNotWritable),
        (EROFS, .destinationNotWritable), (ENOTDIR, .notADirectory),
        (ENOENT, .volumeUnavailable), (ELOOP, .volumeUnavailable), (EIO, .volumeUnavailable),
    ])
    func inspectionFailuresNeverIgnoreEPERM(_ code: Int32, _ expected: HostProbeError) {
        #expect(SystemStorageProbe.inspectionFailure(code) == expected)
    }

    @Test func unwritableDirectoryIsNotCapacity() throws {
        try #require(geteuid() != 0, "This permission regression requires the unprivileged Cloud test account.")
        try withFixture { root in
            let selected = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            try #require(chmod(root.path, 0o500) == 0)
            defer { _ = chmod(root.path, 0o700) }
            #expect(SystemStorageProbe(storageRoot: root, expectedVolume: selected).observe()
                == .unavailable(.destinationNotWritable))
        }
    }

    @Test func searchableWritableDirectoryDoesNotRequireListingPermission() throws {
        try withFixture { root in
            let selected = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            try #require(chmod(root.path, 0o300) == 0)
            defer { _ = chmod(root.path, 0o700) }
            let result = SystemStorageProbe(storageRoot: root, expectedVolume: selected).observe()
            guard case .available = result else { Issue.record("Search/write access should permit this observation."); return }
        }
    }

    @Test func replacedDirectoryBindingIsRefusedWithoutRemovingEitherDirectory() throws {
        try withFixture { root in
            let target = root.appending(path: "selected"), preserved = root.appending(path: "preserved")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            #expect(throws: HostProbeError.volumeUnavailable) {
                try SystemStorageProbe.withDirectory(at: target, allowMissingSuffix: false) { descriptor in
                    try FileManager.default.moveItem(at: target, to: preserved)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    #expect(fcntl(descriptor, F_GETFD) >= 0)
                }
            }
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["selected", "preserved"])
        }
    }

    @Test func newlyAppearedMissingSuffixInvalidatesTheAncestorObservation() throws {
        try withFixture { root in
            let target = root.appending(path: "appeared/Guesthouse")
            #expect(throws: HostProbeError.volumeUnavailable) {
                try SystemStorageProbe.withDirectory(at: target, allowMissingSuffix: true) { _ in
                    try FileManager.default.createDirectory(at: root.appending(path: "appeared"),
                        withIntermediateDirectories: false)
                }
            }
            let contents = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "appeared").path)
            #expect(contents.isEmpty)
        }
    }

    @Test func existingAncestorLinkMeasuresItsTargetVolumeNotItsSpelling() throws {
        try withFixture { root in
            let selected = try SystemStorageProbe.identifyVolume(atExistingDirectory: root)
            let directory = root.appending(path: "directory")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let alias = root.appending(path: "alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            let result = SystemStorageProbe(storageRoot: alias.appending(path: "directory"), expectedVolume: selected).observe()
            guard case .available = result else { Issue.record("Expected the existing target volume's capacity."); return }
        }
    }

    @Test(arguments: [
        URL(string: "https://example.invalid/storage")!, URL(string: "file://other-host/storage")!,
        URL(string: "file:///storage?query=1")!, URL(string: "file:///storage#fragment")!,
        URL(fileURLWithPath: "/bad\0path"), URL(fileURLWithPath: "/" + String(repeating: "a", count: 1024)),
    ])
    func malformedLocationsNeverReachVolumeSelection(_ url: URL) {
        #expect(SystemStorageProbe(storageRoot: url, expectedVolume: UUID()).observe()
            == .unavailable(.storageRootUnknown))
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GuesthouseStorageProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
