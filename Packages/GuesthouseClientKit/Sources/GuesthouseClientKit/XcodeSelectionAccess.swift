import Darwin
import Foundation
import GuesthouseCore
import XPC

/// A read-only copy of the user's already-open selection (#26, MVP-PLAN.md §3).
/// The picker owns security-scoped access until the query finishes. This object never
/// opens a path, resolves a bookmark, mutates a file or runs a process.
public final class XcodeSelectionAccess: Sendable {
    let handoff: FileHandoff
    private let descriptor: Int32

    public init(borrowing descriptor: Int32) throws(XcodeSelectionFailure) {
        guard descriptor >= 0, fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY else { throw .unavailable }
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { throw .unavailable }
        self.descriptor = owned
        handoff = FileHandoff(kind: .fileDescriptor(token: UUID()), displayName: "Xcode.app", expectedBundleIdentifier: "com.apple.dt.Xcode")
    }
    deinit { close(descriptor) }

    func attach(to frame: XPCDictionary) {
        frame.withUnsafeUnderlyingDictionary { xpc_dictionary_set_fd($0, "selectedDirectory", descriptor) }
    }

    static func validate(_ request: RuntimeRequest, selection: XcodeSelectionAccess?) throws(GuesthouseError) {
        if case .inspectXcode(let handoff) = request {
            guard let selection, selection.handoff == handoff else { throw .invalidRequest(.malformed) }
        } else if selection != nil { throw .invalidRequest(.malformed) }
    }
}
