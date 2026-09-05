import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeStorageLocationTests {
    @Test func theRootIsApplicationSupportUnderTheGivenHome() {
        #expect(RuntimeStorageLocation.defaultRoot(home: URL(fileURLWithPath: "/Users/dev")).path == "/Users/dev/Library/Application Support/Guesthouse")
    }

    @Test func theDefaultRootIsDerivedFromTheAccountHome() throws {
        let home = try #require(RuntimeStorageLocation.accountHomeDirectory())
        #expect(!home.path.isEmpty)
        // The account's home, not the caller's own: a sandboxed process's home is its
        // container, and the runtime stores nothing there (MVP-PLAN.md §3, "Local storage").
        #expect(!home.path.contains("/Library/Containers/"))
        #expect(RuntimeStorageLocation.defaultRoot()?.path == RuntimeStorageLocation.defaultRoot(home: home).path)
    }

    @Test func overlappingLookupsAllReadTheSameHome() async throws {
        // The wizard resolves the root inside a detached task on every check, so a Try again
        // can overlap the check it is retrying. With the shared static record this asserts
        // nothing on a lucky run, but a torn or substituted `pw_dir` shows up as a disagreement.
        let expected = try #require(RuntimeStorageLocation.accountHomeDirectory()).path
        let answers = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<64 {
                group.addTask { RuntimeStorageLocation.accountHomeDirectory()?.path }
            }
            return await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(answers.count == 64)
        #expect(answers.allSatisfy { $0 == expected })
    }

    @Test func anUnreadableAccountRecordNamesNoRoot() {
        // There is no fallback by design: `homeDirectoryForCurrentUser` is the container in
        // the sandboxed GUI and the real home in the runtime, so returning it here would put
        // the two processes back on different paths — silently, and in only one of them.
        // The optional is the whole contract, so what is asserted is that callers must handle
        // nil rather than receive a substitute.
        #expect(RuntimeStorageLocation.defaultRoot(home: URL(fileURLWithPath: "/Users/dev")).path.hasPrefix("/Users/dev"))
        let unresolved: URL? = nil
        #expect(unresolved.map(RuntimeStorageLocation.defaultRoot(home:)) == nil)
    }
}
