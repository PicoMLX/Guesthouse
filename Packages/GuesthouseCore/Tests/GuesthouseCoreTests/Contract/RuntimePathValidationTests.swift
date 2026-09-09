import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimePathValidationTests {
    /// Every invocation owns its tree. No shared directories, external targets or host changes.
    static func withTree(_ body: (URL, URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "guesthouse-path-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "root")
        let outside = base.appending(path: "outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try body(base, root, outside)
    }

    @Test func wholeUUIDNamesAreAccepted() throws {
        let name = "guesthouse-1a2b3c4d-0000-4000-8000-000000000000"
        try RequestValidator.validateVMName(name)
        #expect(name == EnvironmentID(uuid: try #require(UUID(uuidString: "1a2b3c4d-0000-4000-8000-000000000000"))).tartVMName)
    }

    @Test(arguments: ["", "ubuntu", "guesthouse-1a2b3c4d", "guesthouse-1A2B3C4D-0000-4000-8000-000000000000",
                      "GUESTHOUSE-1a2b3c4d-0000-4000-8000-000000000000",
                      "../guesthouse-1a2b3c4d-0000-4000-8000-000000000000",
                      "guesthouse-1a2b3c4d-0000-4000-8000-000000000000\n"])
    func invalidNamesAreFixedRejections(name: String) {
        #expect(throws: RequestValidationError.invalidVMName) { try RequestValidator.validateVMName(name) }
    }

    @Test func containedPathsAndInsideLinksResolve() throws {
        try Self.withTree { _, root, _ in
            let inside = root.appending(path: "Xcode.app")
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
            let link = root.appending(path: "alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
            #expect(try RequestValidator.validateContainment(of: inside, within: root) == inside.resolvingSymlinksInPath())
            #expect(try RequestValidator.validateContainment(of: link, within: root) == inside.resolvingSymlinksInPath())
            #expect(try RequestValidator.validateContainment(of: link.appending(path: "new/file"), within: root)
                    == inside.resolvingSymlinksInPath().appending(path: "new/file"))
            #expect(try RequestValidator.validateContainment(of: root, within: root) == root.resolvingSymlinksInPath())
        }
    }

    @Test(arguments: ["", "new/file"])
    func outsideSymlinkAndItsMissingChildrenAreRejected(tail: String) throws {
        try Self.withTree { _, root, outside in
            let link = root.appending(path: "escape")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            #expect(throws: RequestValidationError.pathEscapesRoot) {
                try RequestValidator.validateContainment(of: link.appending(path: tail), within: root)
            }
        }
    }

    @Test func traversalSiblingPrefixAndNonFileURLsAreRejected() throws {
        try Self.withTree { base, root, _ in
            #expect(throws: RequestValidationError.pathEscapesRoot) {
                try RequestValidator.validateContainment(of: root.appending(path: "../outside"), within: root)
            }
            let sibling = base.appending(path: "root-sibling")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
            #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: sibling, within: root) }
            let remote = try #require(URL(string: "https://example.com/private-marker"))
            #expect(throws: RequestValidationError.invalidPath) { try RequestValidator.validateContainment(of: remote, within: root) }
            #expect(throws: RequestValidationError.invalidPath) { try RequestValidator.validateContainment(of: root, within: remote) }
        }
    }

    @Test(arguments: [false, true])
    func danglingLinksRemainRejectedThroughRootAliases(useAlias: Bool) throws {
        try Self.withTree { base, root, outside in
            let dangling = root.appending(path: "dangling")
            try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside.appending(path: "not-created"))
            let alias = base.appending(path: "root-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            let selectedRoot = useAlias ? alias : root
            #expect(throws: RequestValidationError.pathEscapesRoot) {
                try RequestValidator.validateContainment(of: selectedRoot.appending(path: "dangling"), within: selectedRoot)
            }
            #expect(throws: RequestValidationError.pathEscapesRoot) {
                try RequestValidator.validateContainment(of: selectedRoot.appending(path: "dangling/child"), within: selectedRoot)
            }
        }
    }

    @Test(arguments: ["", "subroot"])
    func danglingRootAndItsAncestorsAreRejected(tail: String) throws {
        try Self.withTree { base, _, outside in
            let link = base.appending(path: "dangling-root")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appending(path: "missing"))
            let root = link.appending(path: tail)
            #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: root, within: root) }
            #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: root.appending(path: "Xcode.app"), within: root) }
        }
    }

    @Test func symlinkCyclesAreRejected() throws {
        try Self.withTree { _, root, _ in
            let first = root.appending(path: "first")
            let second = root.appending(path: "second")
            try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
            try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)
            #expect(throws: RequestValidationError.pathEscapesRoot) { try RequestValidator.validateContainment(of: first.appending(path: "child"), within: root) }
        }
    }

    @Test(arguments: [(RequestValidationError.invalidVMName, GuesthouseError.invalidRequest(.invalidVMName)),
                      (.invalidPath, .invalidRequest(.malformed)), (.pathEscapesRoot, .invalidRequest(.pathEscapesAllowedRoot))])
    func pathErrorsMapToFixedDomainErrors(error: RequestValidationError, expected: GuesthouseError) {
        #expect(error.guesthouseError == expected)
        #expect(!error.guesthouseError.recoveryActions.isEmpty)
        #expect(!error.guesthouseError.isRetryable)
    }
}
