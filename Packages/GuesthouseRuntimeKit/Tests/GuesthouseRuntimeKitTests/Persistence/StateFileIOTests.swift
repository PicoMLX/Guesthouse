import Darwin
import Foundation
import GuesthouseCore
import Testing
@testable import GuesthouseRuntimeKit

@Suite struct StateFileIOTests {
    /// Each invocation owns exactly one private temporary file; no shared names or global hooks.
    func withFile(_ body: (Int32, URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "guesthouse-state-io-\(UUID().uuidString)")
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd); unlink(url.path) }
        try body(fd, url)
    }

    @Test(arguments: [0, 1, 65_535, 65_536, 65_537, 131_089])
    func roundTripSpansReadBufferBoundaries(size: Int) throws {
        try withFile { fd, url in
            let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            try StateFileIO.writeAll(fd, bytes, name: .journal)
            #expect(try Data(contentsOf: url) == bytes)
            #expect(try StateFileIO.readAll(fd, from: 0, name: .journal) == bytes)
        }
    }

    @Test(arguments: [(0, "hello"), (3, "lo"), (5, ""), (7, "")])
    func readsFromTheRequestedOffset(offset: Int, expected: String) throws {
        try withFile { fd, url in
            try Data("hello".utf8).write(to: url)
            #expect(try StateFileIO.readAll(fd, from: off_t(offset), name: .snapshot) == Data(expected.utf8))
        }
    }

    @Test(arguments: [StateStoreError.File.snapshot, .journal], [0, 1])
    func fileBudgetAcceptsExactLimitAndRejectsOversize(name: StateStoreError.File, extra: Int) throws {
        try withFile { fd, _ in
            let size = (name == .snapshot ? StateFileIO.maximumSnapshotBytes : StateFileIO.maximumJournalBytes) + extra
            try #require(ftruncate(fd, off_t(size)) == 0)
            if extra == 0 {
                #expect(try StateFileIO.readAll(fd, from: 0, name: name).count == size)
            } else {
                var reads = 0
                #expect(throws: StateStoreError.fileUnreadable(name: name)) {
                    try StateFileIO.readAll(fd, from: 0, name: name) { _, _, _ in reads += 1; return 0 }
                }
                #expect(reads == 0)
            }
        }
    }

    @Test(arguments: [StateStoreError.File.snapshot, .journal])
    func fileGrowthCannotBypassTheInitialSizeCheck(name: StateStoreError.File) throws {
        try withFile { fd, _ in
            var reads = 0
            #expect(throws: StateStoreError.fileUnreadable(name: name)) {
                try StateFileIO.readAll(fd, from: 0, name: name) { _, _, capacity in
                    reads += 1
                    return capacity // Deterministic continuously growing input, no disk mutation.
                }
            }
            let limit = name == .snapshot ? StateFileIO.maximumSnapshotBytes : StateFileIO.maximumJournalBytes
            #expect(reads == limit / (64 * 1024) + 1)
        }
    }

    @Test func failedSeekDoesNotAttemptARead() {
        var calls = 0
        #expect(throws: StateStoreError.fileUnreadable(name: .journal)) {
            try StateFileIO.readAll(-1, from: 0, name: .journal) { _, _, _ in calls += 1; return 0 }
        }
        #expect(calls == 0)
    }

    @Test(arguments: [StateStoreError.File.snapshot, .journal])
    func tailGrowthBudgetIncludesItsStartingOffset(name: StateStoreError.File) throws {
        try withFile { fd, _ in
            let limit = name == .snapshot ? StateFileIO.maximumSnapshotBytes : StateFileIO.maximumJournalBytes
            var reads = 0
            let exact = try StateFileIO.readAll(fd, from: off_t(limit - 2), name: name) { _, _, _ in
                reads += 1; return reads == 1 ? 2 : 0
            }
            #expect(exact.count == 2)
            reads = 0
            #expect(throws: StateStoreError.fileUnreadable(name: name)) {
                try StateFileIO.readAll(fd, from: off_t(limit - 2), name: name) { _, _, _ in
                    reads += 1; return 2
                }
            }
            #expect(reads == 2)
            for offset in [off_t(-1), off_t(limit + 1), off_t.max] {
                reads = 0
                #expect(throws: StateStoreError.fileUnreadable(name: name)) {
                    try StateFileIO.readAll(fd, from: offset, name: name) { _, _, _ in reads += 1; return 0 }
                }
                #expect(reads == 0)
            }
        }
    }

    @Test func readRetriesInterruptionAndAccumulatesShortReads() throws {
        try withFile { fd, url in
            try Data("hello".utf8).write(to: url)
            var calls = 0
            let bytes = try StateFileIO.readAll(fd, from: 0, name: .snapshot) { descriptor, buffer, count in
                calls += 1
                if calls == 1 { errno = EINTR; return -1 }
                return Darwin.read(descriptor, buffer, min(2, count))
            }
            #expect(bytes == Data("hello".utf8))
            #expect(calls == 5) // Interruption, 2+2+1 bytes, then EOF.
        }
    }

    @Test func aLateReadFailureNeverReturnsThePartialBytes() throws {
        try withFile { fd, url in
            try Data("hello".utf8).write(to: url)
            var calls = 0
            #expect(throws: StateStoreError.fileUnreadable(name: .snapshot)) {
                try StateFileIO.readAll(fd, from: 0, name: .snapshot) { descriptor, buffer, _ in
                    calls += 1
                    if calls == 1 { return Darwin.read(descriptor, buffer, 2) }
                    errno = EIO; return -1
                }
            }
            #expect(calls == 2)
            #expect(try Data(contentsOf: url) == Data("hello".utf8))
        }
    }

    @Test func writeRetriesInterruptionWithoutDuplicatingShortWrites() throws {
        try withFile { fd, url in
            var calls = 0
            try StateFileIO.writeAll(fd, Data("abcdefg".utf8), name: .journal) { descriptor, buffer, count in
                calls += 1
                if calls == 1 { errno = EINTR; return -1 }
                return Darwin.write(descriptor, buffer, min(3, count))
            }
            #expect(try Data(contentsOf: url) == Data("abcdefg".utf8))
            #expect(calls == 4)
        }
    }

    @Test(arguments: [(0, Int32(0)), (-1, EIO), (-1, ENOSPC), (-1, EAGAIN)])
    func writeRefusesNoProgressAndNonInterruptionFailures(result: Int, failure: Int32) {
        var calls = 0
        #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try StateFileIO.writeAll(-1, Data([1]), name: .journal) { _, _, _ in
                calls += 1; errno = failure; return result
            }
        }
        #expect(calls == 1)
    }

    @Test func aFailedWriteCanLeaveAnUncertainPrefix() throws {
        try withFile { fd, url in
            var calls = 0
            #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
                try StateFileIO.writeAll(fd, Data("hello".utf8), name: .journal) { descriptor, buffer, _ in
                    calls += 1
                    if calls == 1 { return Darwin.write(descriptor, buffer, 2) }
                    errno = ENOSPC; return -1
                }
            }
            #expect(calls == 2)
            let partial = try Data(contentsOf: url)
            #expect(partial == Data("he".utf8))
        }
    }

    @Test func anEmptyWriteDoesNotDereferenceOrCallTheWriter() throws {
        var calls = 0
        try StateFileIO.writeAll(-1, Data(), name: .snapshot) { _, _, _ in calls += 1; return -1 }
        #expect(calls == 0)
    }

    @Test func aFullBarrierDoesNotAlsoRunTheFallback() throws {
        var fullCalls = 0, fallbackCalls = 0
        try StateFileIO.fullySynchronize(-1, name: .journal, fullSync: { fd in
            #expect(fd == -1); fullCalls += 1; return 0
        }, fallbackSync: { _ in fallbackCalls += 1; return 0 })
        #expect(fullCalls == 1)
        #expect(fallbackCalls == 0)
    }

    @Test(arguments: [ENOTSUP, ENOTTY, EINVAL, EPERM, ENODEV])
    func theRetainedFallbackPolicyRunsFsyncOnce(failure: Int32) throws {
        var fullCalls = 0, fallbackCalls = 0
        try StateFileIO.fullySynchronize(-1, name: .stateDirectory, fullSync: { _ in
            fullCalls += 1; errno = failure; return -1
        }, fallbackSync: { fd in
            #expect(fd == -1); fallbackCalls += 1; return 0
        })
        #expect(fullCalls == 1)
        #expect(fallbackCalls == 1)
    }

    @Test(arguments: [EIO, EBADF, EINTR])
    func anUnlistedFullBarrierFailureNeverFallsBack(failure: Int32) {
        var fallbackCalls = 0
        #expect(throws: StateStoreError.fileUnwritable(name: .snapshot)) {
            try StateFileIO.fullySynchronize(-1, name: .snapshot, fullSync: { _ in
                errno = failure; return -1
            }, fallbackSync: { _ in fallbackCalls += 1; return 0 })
        }
        #expect(fallbackCalls == 0)
    }

    @Test(arguments: [EIO, EBADF, EINTR])
    func aFailedFallbackIsNeverReportedAsDurable(failure: Int32) {
        var fallbackCalls = 0
        #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try StateFileIO.fullySynchronize(-1, name: .journal, fullSync: { _ in
                errno = ENOTSUP; return -1
            }, fallbackSync: { _ in fallbackCalls += 1; errno = failure; return -1 })
        }
        #expect(fallbackCalls == 1)
    }

    @Test func nativeBarrierAcceptsAnOwnedTemporaryFile() throws {
        try withFile { fd, url in
            try StateFileIO.writeAll(fd, Data("saved".utf8), name: .snapshot)
            try StateFileIO.fullySynchronize(fd, name: .snapshot)
            #expect(try Data(contentsOf: url) == Data("saved".utf8))
        }
    }

    @Test func independentOpensContendUntilTheOwnerUnlocks() throws {
        try withFile { first, url in
            let second = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            try #require(second >= 0)
            defer { close(second) }
            #expect(StateFileIO.lock(first, LOCK_EX | LOCK_NB))
            #expect(!StateFileIO.lock(second, LOCK_SH | LOCK_NB))
            #expect(!StateFileIO.lock(second, LOCK_EX | LOCK_NB))
            #expect(StateFileIO.lock(first, LOCK_UN))
            #expect(StateFileIO.lock(second, LOCK_EX | LOCK_NB))
        }
    }

    @Test func advisoryLockRetriesOnlyInterruption() {
        var calls = 0
        let acquired = StateFileIO.lock(-1, LOCK_EX) { fd, operation in
            #expect(fd == -1)
            #expect(operation == LOCK_EX)
            calls += 1
            if calls < 3 { errno = EINTR; return -1 }
            return 0
        }
        #expect(acquired)
        #expect(calls == 3)
    }

    @Test(arguments: [EBADF, EWOULDBLOCK, ENOTSUP])
    func aLockFailureReturnsWithoutSpinning(failure: Int32) {
        var calls = 0
        #expect(!StateFileIO.lock(-1, LOCK_EX | LOCK_NB) { _, _ in
            calls += 1; errno = failure; return -1
        })
        #expect(calls == 1)
    }

    @Test func versionCapturesIdentityAndBothFullTimestamps() {
        let info = stat()
        let baseline = StateFileVersion(info)
        func changed(_ update: (inout stat) -> Void) -> StateFileVersion {
            var altered = info
            update(&altered)
            return StateFileVersion(altered)
        }
        #expect(baseline == StateFileVersion(info))
        #expect(changed { $0.st_dev = 1 } != baseline)
        #expect(changed { $0.st_ino = 1 } != baseline)
        #expect(changed { $0.st_mtimespec.tv_sec = 1 } != baseline)
        #expect(changed { $0.st_mtimespec.tv_nsec = 1 } != baseline)
        #expect(changed { $0.st_ctimespec.tv_sec = 1 } != baseline)
        #expect(changed { $0.st_ctimespec.tv_nsec = 1 } != baseline)
        #expect(changed { $0.st_ctimespec.tv_nsec = 1 }.identity == baseline.identity)
    }

    @Test func nativeVersionReadMatchesTheOpenDescriptor() throws {
        try withFile { fd, _ in
            var info = stat()
            try #require(fstat(fd, &info) == 0)
            #expect(try StateFileIO.version(fd, name: .journal) == StateFileVersion(info))
        }
    }

    @Test func aFailedVersionReadHasOnlyALogicalFileLabel() {
        #expect(throws: StateStoreError.fileUnwritable(name: .journal)) {
            try StateFileIO.version(-1, name: .journal)
        }
    }
}
