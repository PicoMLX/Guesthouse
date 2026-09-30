import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
import XPC
@testable import GuesthouseClientKit

@Suite(.timeLimit(.minutes(1))) struct XcodeSelectionAccessTests {
    @Test func bindingRejectsMissingMismatchedAndUnrelatedGrantsBeforeConnection() throws {
        let fixture = try Directory()
        defer { fixture.remove() }
        let first = try XcodeSelectionAccess(borrowing: fixture.descriptor)
        let second = try XcodeSelectionAccess(borrowing: fixture.descriptor)
        let connections = Mutex(0)
        let transport = XPCRuntimeTransport(incoming: { _ in }, interrupted: { _ in }, connect: { _, _ in
            connections.withLock { $0 += 1 }
            throw RuntimeSessionFailure(cause: .connectionLost)
        })
        let requests: [(RuntimeRequest, XcodeSelectionAccess?)] = [
            (.inspectXcode(first.handoff), nil), (.inspectXcode(first.handoff), second),
            (.runtimeVersion, first), (.importXcode(EnvironmentID(), first.handoff), first),
            (.inspectXcode(.init(kind: .securityScopedBookmark(Data([1])), displayName: "Xcode.app")), first)
        ]
        for (request, selection) in requests {
            #expect(throws: GuesthouseError.invalidRequest(.malformed)) {
                try transport.send(.init(request: request), selection: selection) { _ in Issue.record("Unexpected send") }
            }
        }
        #expect(connections.withLock { $0 } == 0)
    }

    @Test func invalidAndWritableDescriptorsCannotBecomeSelectionAccess() throws {
        #expect(throws: XcodeSelectionFailure.unavailable) { try XcodeSelectionAccess(borrowing: -1) }
        let fixture = try Directory()
        defer { fixture.remove() }
        let file = fixture.url.appending(path: "file")
        try Data().write(to: file)
        let writable = open(file.path, O_RDWR | O_CLOEXEC)
        try #require(writable >= 0)
        defer { close(writable) }
        #expect(throws: XcodeSelectionFailure.unavailable) { try XcodeSelectionAccess(borrowing: writable) }
        let closed = dup(writable)
        try #require(closed >= 0)
        close(closed)
        #expect(throws: XcodeSelectionFailure.unavailable) { try XcodeSelectionAccess(borrowing: closed) }
    }

    @Test func nativeTransportSendsTheOwnedSelectionAfterCallerCloseAndRename() async throws {
        let fixture = try Directory()
        defer { fixture.remove() }
        var info = stat()
        try #require(fstat(fixture.descriptor, &info) == 0)
        let inode = info.st_ino
        let selection = try XcodeSelectionAccess(borrowing: fixture.descriptor)
        try fixture.handle.close()
        try FileManager.default.moveItem(at: fixture.url, to: fixture.moved)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        let sessions = Mutex<XPCSession?>(nil)
        let listener = XPCListener { request in
            request.accept { session in
                sessions.withLock { $0 = session }
                return Receiver(inode: inode, handoff: selection.handoff)
            }
        }
        let transport = XPCRuntimeTransport(incoming: { _ in Issue.record("Unexpected push") }, interrupted: { _ in }, connect: { _, dropped in
            NativeRuntimeSession(try XPCSession(endpoint: listener.endpoint, options: .inactive, cancellationHandler: { _ in dropped() }))
        })
        defer {
            transport.retireCurrent()
            sessions.withLock { $0 }?.cancel(reason: "test done")
            listener.cancel()
        }
        let (stream, reply) = AsyncStream<Result<RuntimeEvent, RuntimeSessionFailure>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        try transport.send(.init(request: .inspectXcode(selection.handoff)), selection: selection) {
            reply.yield($0); reply.finish()
        }
        var iterator = stream.makeAsyncIterator()
        #expect(try #require(await iterator.next()).get() == .xcodeSelection(.rejected(.notXcode)))
    }

    @Test func oneShotQueryReturnsOnlyCandidatesOrTypedFailures() async throws {
        let fixture = try Directory()
        defer { fixture.remove() }
        let selection = try XcodeSelectionAccess(borrowing: fixture.descriptor)
        let candidate = try #require(XcodeCandidate(version: SemanticVersion("26.6")!, build: "17F113"))
        let cases: [(RuntimeEvent, RuntimeXcodeInspectionQuery.Outcome)] = [
            (.xcodeSelection(.candidate(candidate)), .success(candidate)),
            (.xcodeSelection(.rejected(.notXcode)), .failure(.selection(.notXcode))),
            (.failed(OperationID(), .unauthorizedCaller), .failure(.runtime(.unauthorizedCaller))),
            (.hostPreflight(PreflightCheck.run(snapshot: HostProbeSnapshot())), .failure(.connection(.init(cause: .malformedResponse))))
        ]
        for (event, expected) in cases {
            let session = SelectionSession(event: event)
            defer { session.release() }
            #expect(await RuntimeXcodeInspectionQuery.perform(selection: selection, connect: { _, _ in session },
                deadline: { try await Task.sleep(for: .seconds(60)) }) == expected)
            #expect(session.sends.withLock { $0 } == 1 && session.canceled.withLock { $0 } == 1)
        }
    }

    @Test(arguments: [false, true])
    func timeoutOrCancellationClosesTheSessionAndLateRepliesNeverReplay(cancel: Bool) async throws {
        let fixture = try Directory()
        defer { fixture.remove() }
        let selection = try XcodeSelectionAccess(borrowing: fixture.descriptor)
        let (started, sent) = AsyncStream<Void>.makeStream()
        let session = SelectionSession(didSend: { sent.yield(()); sent.finish() })
        defer { session.release(); sent.finish() }
        let task = Task {
            await RuntimeXcodeInspectionQuery.perform(selection: selection, connect: { _, _ in session }, deadline: {
                if cancel { try await Task.sleep(for: .seconds(60)) }
            })
        }
        for await _ in started { break }
        if cancel { task.cancel() }
        #expect(await task.value == .failure(cancel ? .canceled : .timedOut))
        #expect(session.canceled.withLock { $0 } == 1)
        session.reply.withLock { $0 }?(.success(.xcodeSelection(.rejected(.notXcode))))
        #expect(session.sends.withLock { $0 } == 1)
    }

    @Test func alreadyCanceledInspectionDoesNotConnect() async throws {
        let fixture = try Directory()
        defer { fixture.remove() }
        let selection = try XcodeSelectionAccess(borrowing: fixture.descriptor)
        let (gate, resume) = AsyncStream<Void>.makeStream()
        defer { resume.finish() }
        let task = Task {
            for await _ in gate { break }
            return await RuntimeXcodeInspectionQuery.perform(selection: selection, connect: { _, _ in
                Issue.record("Canceled inspection must not connect")
                return SelectionSession()
            }, deadline: {})
        }
        task.cancel()
        #expect(await task.value == .failure(.canceled))
    }

    private final class SelectionSession: RuntimeClientSession {
        typealias Reply = @Sendable (Result<RuntimeEvent, RuntimeSessionFailure>) -> Void
        let event: RuntimeEvent?
        let didSend: @Sendable () -> Void
        let sends = Mutex(0), canceled = Mutex(0), reply = Mutex<Reply?>(nil)
        init(event: RuntimeEvent? = nil, didSend: @escaping @Sendable () -> Void = {}) { self.event = event; self.didSend = didSend }
        func activate() throws {}
        func cancel() { canceled.withLock { $0 += 1 } }
        func send(_ payload: Data, reply: @escaping Reply) { Issue.record("Selection was dropped") }
        func send(_ payload: Data, selection: XcodeSelectionAccess?, reply: @escaping Reply) {
            do {
                let request = try RequestValidator.decode(payload).request
                try XcodeSelectionAccess.validate(request, selection: selection)
                #expect(selection != nil)
            } catch { Issue.record("Invalid selection binding") }
            sends.withLock { $0 += 1 }; self.reply.withLock { $0 = reply }; didSend()
            if let event { reply(.success(event)) }
        }
        func release() { reply.withLock { $0 = nil } }
    }

    private struct Receiver: XPCPeerHandler {
        let inode: ino_t
        let handoff: FileHandoff
        func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
            do {
                let epoch = Int64(RuntimeProtocolVersion.current.rawValue)
                let bytes = try RawRuntimeFrame.payload(message, expectedVersion: epoch, allowSelectedDirectory: true)
                #expect(try RequestValidator.decode(bytes).request == .inspectXcode(handoff))
                message.withUnsafeUnderlyingDictionary { dictionary in
                    #expect(xpc_dictionary_get_count(dictionary) == 3)
                    let descriptor = xpc_dictionary_dup_fd(dictionary, "selectedDirectory")
                    defer { if descriptor >= 0 { close(descriptor) } }
                    var info = stat()
                    #expect(descriptor >= 0 && fstat(descriptor, &info) == 0)
                    #expect(info.st_ino == inode && info.st_mode & S_IFMT == S_IFDIR)
                    #expect(fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY)
                }
                return try RawRuntimeFrame.encode(RuntimeEventEnvelope(event: .xcodeSelection(.rejected(.notXcode))).encoded(), protocolVersion: epoch)
            } catch { Issue.record("Native selection fixture failed"); return nil }
        }
    }

    private struct Directory {
        let url = FileManager.default.temporaryDirectory.appending(path: "guesthouse-client-selection-\(UUID())")
        let handle: FileHandle
        var descriptor: Int32 { handle.fileDescriptor }
        var moved: URL { url.appendingPathExtension("moved") }
        init() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try #require(descriptor >= 0)
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        func remove() { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: moved) }
    }
}
