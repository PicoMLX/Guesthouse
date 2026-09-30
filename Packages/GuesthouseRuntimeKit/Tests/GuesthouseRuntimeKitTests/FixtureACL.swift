import Darwin
import Darwin.membership
import Foundation
import Testing

/// Real ACL fixtures with no subprocess or process-runner deadline. Installation reads back
/// principal, allow/deny tag, rights and inheritance before a policy assertion can run.
enum FixtureACL {
    enum Rule: Sendable {
        case everyoneRead, everyoneDenyDelete, everyoneReplace, currentUserReplace
        case everyoneDenyRead, everyoneDenyReadSearch, inheritedRead
    }

    static func install(_ rule: Rule, at url: URL) throws {
        var acl = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        try #require(acl_create_entry(&acl, &entry) == 0)
        let created = try #require(entry)
        let tag: acl_tag_t = switch rule {
        case .everyoneDenyDelete, .everyoneDenyRead, .everyoneDenyReadSearch: ACL_EXTENDED_DENY
         default: ACL_EXTENDED_ALLOW
        }
        try #require(acl_set_tag_type(created, tag) == 0)
        // Apple's kauth_wellknown_guid identifies this UUID as Everybody.
        // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_credential.c
        var qualifier = try #require(UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")).uuid
        if rule == .currentUserReplace {
            try #require(withUnsafeMutablePointer(to: &qualifier) {
                $0.withMemoryRebound(to: UInt8.self, capacity: 16) { mbr_uid_to_uuid(getuid(), $0) }
            } == 0)
        }
        try #require(withUnsafePointer(to: &qualifier) { acl_set_qualifier(created, $0) } == 0)
        var permissions: acl_permset_t?
        try #require(acl_get_permset(created, &permissions) == 0)
        let permissionSet = try #require(permissions)
        let rights: [acl_perm_t] = switch rule {
        case .everyoneRead, .inheritedRead, .everyoneDenyRead: [ACL_READ_DATA] // ACL_LIST_DIRECTORY is the same bit.
        case .everyoneDenyDelete: [ACL_DELETE]
        case .everyoneDenyReadSearch: [ACL_READ_DATA, ACL_EXECUTE]
        case .everyoneReplace, .currentUserReplace: [ACL_ADD_FILE, ACL_DELETE_CHILD]
        }
        for right in rights { try #require(acl_add_perm(permissionSet, right) == 0) }
        if rule == .inheritedRead {
            var flags: acl_flagset_t?
            try #require(acl_get_flagset_np(UnsafeMutableRawPointer(created), &flags) == 0)
            let flagSet = try #require(flags)
            try #require(acl_add_flag_np(flagSet, ACL_ENTRY_DIRECTORY_INHERIT) == 0)
        }
        let granted = try #require(acl)
        try #require(acl_valid(granted) == 0)
        try #require(acl_set_link_np(url.path, ACL_TYPE_EXTENDED, granted) == 0)
        // Read back the real fixture before exercising either positive or negative policy.
        let installed = try #require(acl_get_link_np(url.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(installed)) }
        var observed: acl_entry_t?, observedTag = ACL_UNDEFINED_TAG
        try #require(acl_get_entry(installed, ACL_FIRST_ENTRY.rawValue, &observed) == 0)
        let observedEntry = try #require(observed)
        try #require(acl_get_tag_type(observedEntry, &observedTag) == 0 && observedTag == tag)
        let observedID = try #require(acl_get_qualifier(observedEntry))
        defer { acl_free(observedID) }
        try #require(withUnsafePointer(to: &qualifier) { memcmp(observedID, $0, 16) } == 0)
        var observedPermissions: acl_permset_t?
        try #require(acl_get_permset(observedEntry, &observedPermissions) == 0)
        let observedSet = try #require(observedPermissions)
        for right in rights { try #require(acl_get_perm_np(observedSet, right) == 1) }
        var observedFlags: acl_flagset_t?
        try #require(acl_get_flagset_np(UnsafeMutableRawPointer(observedEntry), &observedFlags) == 0)
        let flagSet = try #require(observedFlags)
        try #require(acl_get_flag_np(flagSet, ACL_ENTRY_DIRECTORY_INHERIT) == (rule == .inheritedRead ? 1 : 0))
    }
}
