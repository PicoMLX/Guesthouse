import Darwin
import Foundation
import GuesthouseCore
import Synchronization
import Testing
import XPC

/// #26 transport feasibility only: anonymous endpoints in an unsandboxed test runner.
/// This is not signed GUI sandbox access, caller authentication or Xcode validation proof.
@Suite(.timeLimit(.minutes(1))) struct XPCFileDescriptorHandoffTests {
    @Test func directoryDescriptorTravelsWithCodablePayloadAndSurvivesSenderCloseAndRename() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-fd-\(UUID())")
        let selected = base.appending(path: "Selected.app"), moved = base.appending(path: "Moved.app")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("selected".utf8).write(to: selected.appending(path: "marker"))
        let original = open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(original >= 0)
        let handle = FileHandle(fileDescriptor: original, closeOnDealloc: true)
        var info = stat()
        try #require(fstat(original, &info) == 0)
        let token = UUID()
        let bytes = try JSONEncoder().encode(Selection(token: token))
        let message = try RawRuntimeFrame.encode(bytes, protocolVersion: Int64(RuntimeProtocolVersion.current.rawValue))
        // The Swift FileDescriptor subscript requires macOS 27. These public C APIs are
        // available since macOS 10.7 and work through the existing native dictionary bridge.
        message.withUnsafeUnderlyingDictionary { xpc_dictionary_set_fd($0, "selectedDirectory", original) }
        try handle.close()
        try FileManager.default.moveItem(at: selected, to: moved)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: selected.appending(path: "marker"))
        // Default framing still refuses grants; only the named authenticated inspection
        // ingress opts in and binds the grant to its decoded request.
        #expect(throws: RawRuntimeFrame.Failure.malformed) {
            try RawRuntimeFrame.payload(message, expectedVersion: Int64(RuntimeProtocolVersion.current.rawValue))
        }
        #expect(try RawRuntimeFrame.payload(message, expectedVersion: Int64(RuntimeProtocolVersion.current.rawValue),
            allowSelectedDirectory: true) == bytes)
        let fixture = try Fixture(token: token)
        defer { fixture.cancel() }
        let reply = try await fixture.request(message)
        #expect(reply.accepted == true)
        #expect(reply.inode == UInt64(info.st_ino))
        #expect(reply.selectedBytes == true)
        #expect(reply.readOnly == true)
    }

    @Test(arguments: [false, true]) func missingOrIntegerDescriptorIsNotAFileGrant(integer: Bool) async throws {
        let token = UUID()
        let fixture = try Fixture(token: token)
        defer { fixture.cancel() }
        var message = try RawRuntimeFrame.encode(JSONEncoder().encode(Selection(token: token)),
            protocolVersion: Int64(RuntimeProtocolVersion.current.rawValue))
        if integer { message["selectedDirectory"] = Int64(0) }
        #expect(try await fixture.request(message).accepted == false)
    }

    private struct Selection: Codable { let token: UUID }
    private struct Reply: Sendable {
        let accepted: Bool?, inode: UInt64?, selectedBytes: Bool?, readOnly: Bool?
    }

    private struct Receiver: XPCPeerHandler {
        let token: UUID
        func handleIncomingRequest(_ message: XPCDictionary) -> XPCDictionary? {
            var reply = XPCDictionary()
            reply["accepted"] = false
            return message.withUnsafeUnderlyingDictionary { dictionary in
                guard xpc_dictionary_get_count(dictionary) == 3,
                      let payload = xpc_dictionary_get_value(dictionary, "payload"), xpc_get_type(payload) == XPC_TYPE_DATA,
                      xpc_data_get_length(payload) <= 1024,
                      let pointer = xpc_data_get_bytes_ptr(payload),
                      let selection = try? JSONDecoder().decode(Selection.self, from: Data(bytes: pointer, count: xpc_data_get_length(payload))),
                      selection.token == token,
                      let value = xpc_dictionary_get_value(dictionary, "selectedDirectory"), xpc_get_type(value) == XPC_TYPE_FD
                else { return reply }
                // dup_fd returns a NEW caller-owned descriptor. The received message keeps its
                // own grant; our copy is closed on every path and is never converted to a path.
                let directory = xpc_dictionary_dup_fd(dictionary, "selectedDirectory")
                guard directory >= 0 else { return reply }
                defer { close(directory) }
                var info = stat()
                guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return reply }
                let file = openat(directory, "marker", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard file >= 0 else { return reply }
                defer { close(file) }
                var bytes = [UInt8](repeating: 0, count: 32)
                let count = read(file, &bytes, bytes.count)
                reply["accepted"] = true
                reply["inode"] = UInt64(info.st_ino)
                reply["selectedBytes"] = count == 8 && Array(bytes.prefix(8)) == Array("selected".utf8)
                reply["readOnly"] = fcntl(directory, F_GETFL) & O_ACCMODE == O_RDONLY
                return reply
            }
        }
    }

    private final class Fixture: Sendable {
        let listener: XPCListener
        let client: XPCSession
        let accepted: SessionOwner
        init(token: UUID) throws {
            let accepted = SessionOwner()
            self.accepted = accepted
            listener = XPCListener { request in
                request.accept { session in
                    accepted.session.withLock { $0 = session }
                    return Receiver(token: token)
                }
            }
            do { client = try XPCSession(endpoint: listener.endpoint) }
            catch { listener.cancel(); throw error }
        }
        func request(_ message: XPCDictionary) async throws -> Reply {
            try await withCheckedThrowingContinuation { continuation in
                client.send(message: message) { result in
                    do {
                        let reply = try result.get()
                        continuation.resume(returning: Reply(accepted: reply["accepted", as: Bool.self],
                            inode: reply["inode", as: UInt64.self], selectedBytes: reply["selectedBytes", as: Bool.self],
                            readOnly: reply["readOnly", as: Bool.self]))
                    }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
        func cancel() {
            client.cancel(reason: "test completed")
            accepted.session.withLock { $0 }?.cancel(reason: "test completed")
            listener.cancel()
        }
    }

    private final class SessionOwner: Sendable {
        let session = Mutex<XPCSession?>(nil)
    }
}
