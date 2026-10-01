import Darwin

/// One private kernel queue, registered while our new child is suspended before user code.
/// Nothing consumes/clears the accumulated flags until the exclusive wait observes exit.
/// A fork permanently leaves descendant cleanup unproven; no child PID/group is adopted.
/// See Apple's kern_event.c filt_procevent (OR flags), kern_fork.c and kern_exec.c.
final class OwnedChildForkObservation: Sendable {
    enum Result: Equatable, Sendable { case unproven, forkObserved, exitedWithoutFork }
    private let descriptor: Int32
    private let pid: pid_t

    init?(pid: pid_t) {
        let fd = kqueue()
        guard fd >= 0 else { return nil }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { close(fd); return nil }
        var change = kevent64_s()
        change.ident = UInt64(pid); change.filter = Int16(EVFILT_PROC)
        change.flags = UInt16(EV_ADD | EV_RECEIPT); change.fflags = UInt32(NOTE_FORK) | UInt32(NOTE_EXIT)
        var receipt = kevent64_s(), timeout = timespec()
        let count = kevent64(fd, &change, 1, &receipt, 1, 0, &timeout)
        guard count == 1, receipt.ident == UInt64(pid), receipt.filter == Int16(EVFILT_PROC),
              receipt.flags & UInt16(EV_ERROR) != 0, receipt.data == 0 else { close(fd); return nil }
        descriptor = fd; self.pid = pid
    }

    /// Call only after this child's WEXITED/WNOWAIT observation, before its sole reap.
    /// Missing/failed/wrong events never establish absence of a fork.
    func afterObservedExit() -> Result {
        var event = kevent64_s(), timeout = timespec()
        let count = kevent64(descriptor, nil, 0, &event, 1, 0, &timeout)
        guard count == 1, event.ident == UInt64(pid), event.filter == Int16(EVFILT_PROC),
              event.flags & UInt16(EV_ERROR) == 0, event.fflags & UInt32(NOTE_EXIT) != 0 else { return .unproven }
        return event.fflags & UInt32(NOTE_FORK) == 0 ? .exitedWithoutFork : .forkObserved
    }

    deinit { close(descriptor) }
}
