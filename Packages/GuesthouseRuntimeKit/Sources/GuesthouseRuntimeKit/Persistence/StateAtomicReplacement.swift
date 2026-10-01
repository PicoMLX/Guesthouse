import Darwin
import Foundation
import GuesthouseCore

extension StateDirectoryAnchor {
    /// Shared snapshot/ownership publication under the existing StateStore lifetime lock.
    /// Fixed exclusive temporary, descriptor protection, file barrier, rename and directory
    /// barrier. A thrown post-publication error never undoes a possibly visible replacement.
    func replace(_ data: Data, at access: StateFileAccess, hooks: StateStoreHooks,
                 write: (Int32, Data) throws -> Void,
                 didPublish: () -> Void = {}) throws(StateStoreError) {
        try withDescriptor { directory in
            let temporary = ".\(access.name).pending"
            let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw StateStoreError.fileUnwritable(name: access.label) }
            defer { Darwin.close(descriptor) }
            var published = false
            defer { if !published { _ = unlinkat(directory, temporary, 0) } }
            try StateFileProtection.prepare(descriptor, kind: .regularFile, name: access.label)
            try write(descriptor, data)
            try hooks.synchronize(descriptor, access.label)
            guard renameat(directory, temporary, directory, access.name) == 0 else {
                throw StateStoreError.fileUnwritable(name: access.label)
            }
            published = true
            didPublish()
            try hooks.synchronize(directory, .stateDirectory)
        }
    }
}
