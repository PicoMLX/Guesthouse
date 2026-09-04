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
    /// `~/Library/Application Support/Guesthouse` in the account's own home directory.
    public static func defaultRoot(home: URL = accountHomeDirectory()) -> URL {
        home.appending(path: "Library/Application Support/Guesthouse")
    }

    /// The account's home directory, read from the password database so a sandboxed caller
    /// gets the same answer as an unsandboxed one.
    public static func accountHomeDirectory() -> URL {
        guard let record = getpwuid(getuid()), let directory = record.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let path = FileManager.default.string(withFileSystemRepresentation: directory, length: strlen(directory))
        guard !path.isEmpty else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
