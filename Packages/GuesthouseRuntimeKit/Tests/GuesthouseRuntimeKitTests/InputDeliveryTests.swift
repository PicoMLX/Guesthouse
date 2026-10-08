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
        #expect(await reachesEOF(descriptor)) // Real EOF while the retained read end remains open.
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

    private func reachesEOF(_ descriptor: Int32) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "Guesthouse.InputDeliveryTests.EOF").async {
                let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                var bytes = [UInt8](repeating: 0, count: 16 << 10)
                var drained = 0
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    let count = Darwin.read(descriptor, &bytes, bytes.count)
                    if count == 0 { continuation.resume(returning: true); return }
                    if count > 0 {
                        drained += count
                        if drained > 4 << 20 { break }
                    } else if errno == EAGAIN {
                        // Cancellation/closure is not EOF. Observe readiness/HUP and retry
                        // the actual read within a bound, including concurrent spawn windows.
                        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                        _ = poll(&item, 1, 100)
                    } else if errno != EINTR { break }
                }
                continuation.resume(returning: false)
            }
        }
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
