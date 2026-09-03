import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct GuesthouseErrorEncodingTests {
    let token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"

    @Test func encodedErrorsCarryOnlySanitizedText() throws {
        let error = GuesthouseError.toolMismatch(tool: "gh", found: SanitizedText(token), expected: "2.80.0")
        let json = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
        #expect(!json.contains(token))
        #expect(json.contains("[redacted:github-token]"))
        let injected = #"{"toolMismatch":{"tool":"gh","found":"\#(token)","expected":"1"}}"#
        let decoded = try JSONDecoder().decode(GuesthouseError.self, from: Data(injected.utf8))
        guard case .toolMismatch(_, let found?, _) = decoded else { Issue.record("wrong case: \(decoded)"); return }
        #expect(found.value == "[redacted:github-token]")
    }

    @Test func missingComponentListsAreBounded() {
        let missing = (0..<100).map { SanitizedText("Component \($0)") }
        let message = GuesthouseError.xcodeComponentsIncomplete(missing: missing).userMessage
        #expect(message.contains("Component 19"))
        #expect(!message.contains("Component 20"))
        #expect(message.contains("and 80 more"))
        #expect(GuesthouseError.xcodeComponentsIncomplete(missing: ["a", "b"]).userMessage.contains("components: a, b."))
    }

    @Test func unterminatedAuthorityAtTheBoundIsRedacted() {
        let value = "https://user:" + String(repeating: "p", count: 700) + "@example.com/repo.git"
        let message = GuesthouseError.downloadVerificationFailed(artifact: SanitizedText(value), check: .digest).userMessage
        #expect(!message.contains("pppp"))
        #expect(message.contains("https://[redacted:userinfo]"))
    }

    @Test func escapesInsideATokenAreStrippedBeforeRedaction() {
        let styled = "ghp_\u{1B}[31mABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab\u{1B}[0m"
        let message = GuesthouseError.toolMismatch(tool: "gh", found: SanitizedText(styled), expected: "1").userMessage
        #expect(!message.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(message.contains("[redacted:github-token]"))
    }

    @Test func cancellationRequiresInspectionBeforeRetry() {
        #expect(GuesthouseError.canceled.recoveryActions.first == .inspectState)
        #expect(!GuesthouseError.canceled.isRetryable)
    }
}
