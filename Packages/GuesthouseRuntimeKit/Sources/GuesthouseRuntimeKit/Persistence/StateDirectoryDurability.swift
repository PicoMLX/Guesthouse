import Darwin
import Foundation
import GuesthouseCore

/// Runtime-internal mechanics for the fixed StateDirectoryAnchor preparation (MVP-PLAN.md §3).
/// The anchor validates managed storage and ancestry around every call. These helpers do not
/// select storage, repair permissions, create/remove entries, or return a permanent capability.
enum StateDirectoryDurability {
    /// Retained ordering: physical ancestry first, then lexical ancestry, each root outward.
    /// Deduplicate path spellings, not just target inodes: a symlink entry has its own parent.
    /// Inputs are validated absolute paths supplied by the anchor, not GUI/repository paths.
    static func parents(lexical: String, physical: String) -> [String] {
        var result: [String] = [], seen: Set<String> = []
        for path in [physical, lexical] {
            var parents: [String] = [], child = path
            while child != "/" {
                let parent = (child as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != child else { break }
                parents.append(parent)
                child = parent
            }
            for parent in parents.reversed() where seen.insert(parent).inserted { result.append(parent) }
        }
        return result
    }

    static func resolve(_ path: String) throws(StateStoreError) -> String {
        guard let resolved = realpath(path, nil) else { throw .insecureDirectory(reason: .ancestryUnresolved) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func synchronize(_ path: String, barrier: StateFileProtection.Barrier) throws(StateStoreError) {
        var expected = stat()
        guard stat(path, &expected) == 0, expected.st_mode & S_IFMT == S_IFDIR,
              StorageProtection.mayHoldEntry(owner: expected.st_uid) else {
            throw .insecureDirectory(reason: .unreadable)
        }
        // A validated lexical ancestor can itself be a symlink (for example /var). Resolve
        // that target explicitly, open its real final component without following a new link,
        // and bind the descriptor to the original ancestor. Its parent is in the plan as well.
        let resolved = try resolve(path)
        let descriptor = open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .insecureDirectory(reason: .unopenable) }
        defer { close(descriptor) }
        try verify(descriptor, path: path, expected: expected)
        do { try barrier(descriptor, .stateDirectory) }
        catch let error as StateStoreError { throw error }
        catch { throw .fileUnwritable(name: .stateDirectory) }
        try verify(descriptor, path: path, expected: expected)
        guard try resolve(path) == resolved else { throw .insecureDirectory(reason: .changed) }
    }

    private static func verify(_ descriptor: Int32, path: String, expected: stat) throws(StateStoreError) {
        var opened = stat(), current = stat()
        guard fstat(descriptor, &opened) == 0, stat(path, &current) == 0,
              sameDirectory(opened, expected), sameDirectory(current, expected) else {
            throw .insecureDirectory(reason: .changed)
        }
        // Parent timestamps legitimately change when unrelated applications update siblings.
        // Do not treat this as a tree-wide version lock or proof against same-user renames.
        // The anchor separately rechecks policy and the state directory's publication version.
    }

    private static func sameDirectory(_ value: stat, _ expected: stat) -> Bool {
        StateFileIdentity(value) == StateFileIdentity(expected) && value.st_mode == expected.st_mode
            && value.st_uid == expected.st_uid && value.st_mode & S_IFMT == S_IFDIR
    }
}
