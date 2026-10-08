import Darwin
import Foundation
import Testing
@testable import GuesthouseRuntimeKit

@Suite(.timeLimit(.minutes(1))) struct InputDeliveryTests {
    @Test func cancellationClosesAFullPipeWithoutReaderProgress() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0)
        let delivery = try InputDelivery(pipe.fileHandleForWriting)
        delivery.start(Data(repeating: 65, count: 4 << 20))
        try #require(await readable(descriptor)) // Actual bytes arrived; the reader does not drain yet.
        #expect(delivery.end == .pending) // A pipe cannot hold the whole four MiB input.
        delivery.cancel()
        try #require(await closed(delivery))
        #expect(delivery.end == .abandoned)
        #expect(await nativePipeReachesEOF(descriptor)) // Real EOF while the retained read end remains open.
    }

    @Test func cancellationBeforeStartClosesTheUnusedWriter() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let delivery = try InputDelivery(pipe.fileHandleForWriting)
        delivery.cancel()
        delivery.start(Data([65]))
        delivery.cancel()
        try #require(await closed(delivery))
        #expect(delivery.end == .abandoned)
        var byte: UInt8 = 0
        #expect(Darwin.read(pipe.fileHandleForReading.fileDescriptor, &byte, 1) == 0)
    }

    @Test func releasingUnstartedDeliveryClosesItsWriter() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        var delivery: InputDelivery? = try InputDelivery(pipe.fileHandleForWriting)
        weak let reference = delivery
        delivery = nil
        #expect(reference == nil)
        try #require(await readable(pipe.fileHandleForReading.fileDescriptor))
        var byte: UInt8 = 0
        #expect(Darwin.read(pipe.fileHandleForReading.fileDescriptor, &byte, 1) == 0)
    }

    @Test func closedReaderReportsEPIPEAndClosesTheWriter() async throws {
        let pipe = Pipe()
        let delivery = try InputDelivery(pipe.fileHandleForWriting)
        try pipe.fileHandleForReading.close()
        delivery.start(Data([65]))
        try #require(await closed(delivery))
        #expect(delivery.end == .failed(EPIPE)) // Descriptor-local suppression keeps the host alive.
    }

    private func closed(_ delivery: InputDelivery) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "Guesthouse.InputDeliveryTests.close").async {
                continuation.resume(returning: delivery.waitUntilClosed(by: .now() + .seconds(5)))
            }
        }
    }
    private func readable(_ descriptor: Int32) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "Guesthouse.InputDeliveryTests.readiness").async {
                var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                continuation.resume(returning: poll(&item, 1, 5_000) == 1 && item.revents & Int16(POLLIN | POLLHUP) != 0)
            }
        }
    }
}
