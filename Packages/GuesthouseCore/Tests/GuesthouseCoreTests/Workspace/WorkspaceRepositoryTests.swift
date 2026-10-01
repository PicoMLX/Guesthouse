import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct WorkspaceRepositoryTests {
    @Test func repositoryRecordsRoundTripWithoutInventingCloneOrPushCompletion() throws {
        let remote = try #require(RemoteURL("https://github.com/Org/App"))
        let base = try #require(BranchName("main")), task = try #require(BranchName("task/change"))
        var repository = WorkspaceRepository(role: .app, remote: remote, baseBranch: base, taskBranch: task)
        #expect(repository.checkoutName.rawValue == "App" && repository.baseSHA == nil && repository.publishedSHA == nil && repository.draftPullRequest == nil)
        repository.baseSHA = CommitSHA(String(repeating: "a", count: 40))
        repository.publishedSHA = CommitSHA(String(repeating: "b", count: 40))
        repository.draftPullRequest = .init(number: 7, url: URL(string: "https://github.com/Org/App/pull/7"))
        #expect(try JSONDecoder().decode(WorkspaceRepository.self, from: JSONEncoder().encode(repository)) == repository)
    }
    @Test func pullRequestLinksMustNameTheExactSupportedRepositoryAndNumber() throws {
        let remote = try #require(RemoteURL("https://github.com/Org/App"))
        #expect(PullRequestReference(number: 7).isValid(for: remote))
        #expect(PullRequestReference(number: 7, url: URL(string: "https://github.com/org/app/pull/7")).isValid(for: remote))
        #expect(!PullRequestReference(number: 0).isValid(for: remote))
        #expect(!PullRequestReference(number: 7).isValid(for: try #require(RemoteURL("https://gitlab.com/Org/App"))))
        for invalid in ["https://github.com/Other/App/pull/7", "https://github.com/Org/App/pull/8", "http://github.com/Org/App/pull/7", "https://github.com/Org/App/PULL/7", "https://github.com/Org/App/pull/7?query=x", "https://github.com/Org/App/pull/7#fragment", "https://user@github.com/Org/App/pull/7", "https://github.com:443/Org/App/pull/7"] {
            #expect(!PullRequestReference(number: 7, url: URL(string: invalid)).isValid(for: remote))
        }
    }
    @Test func destinationSyntaxPreservesFieldsWithoutAllowingAdditionalSpecifierKeys() throws {
        let destination = TestDestination(platform: "iOS Simulator", name: "iPhone 17", os: "26.4")
        #expect(destination.isValid && destination.specifier == "platform=iOS Simulator,name=iPhone 17,OS=26.4")
        #expect(TestDestination.macOS.isValid && TestDestination.macOS.specifier == "platform=macOS")
        #expect(try JSONDecoder().decode(TestDestination.self, from: JSONEncoder().encode(destination)) == destination)
        for invalid in ["", "Phone,OS=1", "a=b", "a\u{0}b", "a\u{202E}b", "a\u{2028}b", "a\u{FFFE}b", String(repeating: "x", count: 129)] {
            #expect(!TestDestination(platform: "iOS Simulator", name: invalid).isValid)
            #expect(!TestDestination(platform: invalid).isValid)
        }
        #expect(TestDestination(platform: "macOS", name: "Developer’s Mac").isValid)
    }
}
