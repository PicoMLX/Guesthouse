import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct RuntimeStorageLocationTests {
    @Test func theRootIsApplicationSupportUnderTheGivenHome() {
        #expect(RuntimeStorageLocation.defaultRoot(home: URL(fileURLWithPath: "/Users/dev")).path == "/Users/dev/Library/Application Support/Guesthouse")
    }

    @Test func theDefaultRootIsDerivedFromTheAccountHome() {
        let home = RuntimeStorageLocation.accountHomeDirectory()
        #expect(!home.path.isEmpty)
        // The account's home, not the caller's own: a sandboxed process's home is its
        // container, and the runtime stores nothing there (MVP-PLAN.md §3, "Local storage").
        #expect(!home.path.contains("/Library/Containers/"))
        #expect(RuntimeStorageLocation.defaultRoot().path == RuntimeStorageLocation.defaultRoot(home: home).path)
    }
}
