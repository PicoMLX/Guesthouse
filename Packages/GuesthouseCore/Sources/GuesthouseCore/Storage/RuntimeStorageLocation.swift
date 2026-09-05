import Darwin
import Foundation

/// Where the runtime keeps everything on this Mac, derived the same way in both processes.
///
/// The GUI is sandboxed and the runtime service is not, so `homeDirectoryForCurrentUser` and
/// `FileManager.url(for: .applicationSupportDirectory …)` do not agree: inside the sandbox
/// they name the app container, which is not where the runtime stores anything. MVP-PLAN.md
/// §3 ("Local storage") says not to assume the two processes resolve Application Support
/// identically, so the canonical root is derived from the account record instead, which the
/// sandbox does not rewrite.
public enum RuntimeStorageLocation: Sendable {
    /// `~/Library/Application Support/Guesthouse` in the given home directory.
    public static func defaultRoot(home: URL) -> URL {
        home.appending(path: "Library/Application Support/Guesthouse")
    }

    /// The canonical root for this account, or `nil` when the account record cannot be read.
    ///
    /// There is deliberately no fallback. `homeDirectoryForCurrentUser` is the container in
    /// the sandboxed GUI and the real home in the runtime service, so falling back to it
    /// restores exactly the disagreement this type exists to prevent — silently, and in only
    /// one of the two processes. A caller that does not know the root must say so instead of
    /// naming the wrong one: the wizard would otherwise tell the user "Everything lives under"
    /// a container path the runtime never writes to, and measure the wrong volume to boot.
    public static func defaultRoot() -> URL? {
        accountHomeDirectory().map { defaultRoot(home: $0) }
    }

    /// The account's home directory, read from the password database so a sandboxed caller
    /// gets the same answer as an unsandboxed one, or `nil` when that record is unavailable.
    ///
    /// This is a nonisolated public function, and the wizard now resolves the root inside a
    /// detached task on every check, so two lookups can overlap — a Try again racing the
    /// preflight it is retrying. `getpwuid` hands back a pointer into the library's own static
    /// record, which the second call is free to overwrite while the first is still reading
    /// `pw_dir`, so the reentrant form with caller-owned storage is the only safe one here.
    public static func accountHomeDirectory() -> URL? {
        // `_SC_GETPW_R_SIZE_MAX` is the suggested size, not a guaranteed one, so ERANGE is
        // answered by doubling rather than by giving up on the account record.
        var capacity = sysconf(_SC_GETPW_R_SIZE_MAX)
        if capacity <= 0 { capacity = 4096 }
        while capacity <= 1 << 20 {
            var record = passwd()
            var found: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            let outcome = buffer.withUnsafeMutableBufferPointer { storage -> (status: Int32, home: URL?) in
                let status = getpwuid_r(getuid(), &record, storage.baseAddress, storage.count, &found)
                guard status == 0 else { return (status, nil) }
                // `pw_dir` points into `storage`, so the string is copied out before it ends.
                guard found != nil, let directory = record.pw_dir else { return (0, nil) }
                let path = FileManager.default.string(withFileSystemRepresentation: directory, length: strlen(directory))
                guard !path.isEmpty else { return (0, nil) }
                return (0, URL(fileURLWithPath: path, isDirectory: true))
            }
            guard outcome.status != 0 else { return outcome.home }
            guard outcome.status == ERANGE else { return nil }
            capacity *= 2
        }
        return nil
    }
}
