import Darwin
import Foundation

// Observe real EOF with bounded bytes/time, including interrupted reads and
// temporary readiness gaps while concurrent native launches borrow descriptors.
func nativePipeReachesEOF(_ descriptor: Int32) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "Guesthouse.native-pipe-EOF").async {
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
                    var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    _ = poll(&item, 1, 100)
                } else if errno != EINTR { break }
            }
            continuation.resume(returning: false)
        }
    }
}
