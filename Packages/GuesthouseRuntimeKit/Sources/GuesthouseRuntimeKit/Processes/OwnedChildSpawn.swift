import Darwin
import Foundation

/// Pins the opened directory, not a pathname checked earlier. This capability guarantees
/// validation-to-chdir identity, not authorization beneath a trusted workspace root.
/// A caller requiring containment must acquire it through root-relative trusted authority.
final class PinnedWorkingDirectory: Sendable {
    fileprivate let descriptor: Int32

    init(_ url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw OwnedChild.Failure.invalidInvocation }
        let opened = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw OwnedChild.Failure.systemCall("open directory", errno) }
        // Never alias 0/1/2: spawn installs stdio before the fchdir action.
        let fd = fcntl(opened, F_DUPFD_CLOEXEC, 3)
        let duplicationError = errno
        close(opened)
        guard fd >= 0 else { throw OwnedChild.Failure.systemCall("pin directory", duplicationError) }
        var information = stat()
        guard fstat(fd, &information) == 0, information.st_mode & S_IFMT == S_IFDIR else {
            let error = errno
            close(fd)
            throw OwnedChild.Failure.systemCall("validate directory", error)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

enum OwnedChildSpawn {
    static func launch(
        executable: URL, arguments: [String], environment: [String: String],
        workingDirectory: PinnedWorkingDirectory?, descriptors: [Int32]
    ) throws -> pid_t {
        guard executable.isFileURL, !executable.path.utf8.contains(0),
              arguments.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) })
        else { throw OwnedChild.Failure.invalidInvocation }
        // Do not mutate process-wide signal policy. Automatic/external reaping invalidates
        // the owned-PID guarantee, so require the service's default SIGCHLD contract.
        var disposition = sigaction()
        guard sigaction(SIGCHLD, nil, &disposition) == 0 else {
            throw OwnedChild.Failure.systemCall("read SIGCHLD policy", errno)
        }
        guard disposition.__sigaction_u.__sa_handler == nil, disposition.sa_flags & SA_NOCLDWAIT == 0 else {
            throw OwnedChild.Failure.systemCall("exclusive reaping unavailable", EINVAL)
        }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "initialize file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "initialize spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        var ownedDescriptors: [Int32] = []
        defer { ownedDescriptors.forEach { close($0) } }
        for (destination, borrowed) in descriptors.enumerated() {
            let copy = fcntl(borrowed, F_DUPFD_CLOEXEC, 3)
            guard copy >= 0 else { throw OwnedChild.Failure.systemCall("duplicate stdio", errno) }
            ownedDescriptors.append(copy)
            try check(posix_spawn_file_actions_adddup2(&actions, copy, Int32(destination)), "attach stdio")
            try check(posix_spawn_file_actions_addclose(&actions, copy), "close child stdio copy")
        }
        if let workingDirectory {
            try check(posix_spawn_file_actions_addfchdir(&actions, workingDirectory.descriptor), "bind directory")
            try check(posix_spawn_file_actions_addclose(&actions, workingDirectory.descriptor), "close child directory")
        }
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask), "reset signal mask")
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), "reset signal dispositions")
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "set spawn flags")
        var pid: pid_t = 0
        let status = try withCStringArray([executable.path] + arguments) { argv in
            try withCStringArray(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }) { envp in
                executable.path.withCString { path in
                    withExtendedLifetime(workingDirectory) {
                        posix_spawn(&pid, path, &actions, &attributes, argv, envp)
                    }
                }
            }
        }
        try check(status, "spawn")
        guard pid > 0 else { throw OwnedChild.Failure.systemCall("invalid spawned pid", EINVAL) }
        return pid
    }

    private static func check(_ error: Int32, _ operation: String) throws {
        guard error == 0 else { throw OwnedChild.Failure.systemCall(operation, error) }
    }

    private static func withCStringArray<T>(_ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { pointers.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else { throw OwnedChild.Failure.systemCall("allocate arguments", ENOMEM) }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }
}
