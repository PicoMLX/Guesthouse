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

    @Test func missingComponentListsAreBoundedInMessagesAndPayloads() throws {
        let missing = MissingComponents((0..<100).map { SanitizedText("Component \($0)") })
        let error = GuesthouseError.xcodeComponentsIncomplete(missing: missing)
        let message = error.userMessage
        #expect(message.contains("Component 19"))
        #expect(!message.contains("Component 20"))
        #expect(message.contains("and 80 more"))
        #expect(GuesthouseError.xcodeComponentsIncomplete(missing: ["a", "b"]).userMessage.contains("components: a, b."))
        let json = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
        #expect(!json.contains("Component 20"))
        #expect(json.contains("\"omitted\":80"))
        let oversized = #"{"listed":[\#((0..<50).map { "\"c\($0)\"" }.joined(separator: ","))],"omitted":0}"#
        let decoded = try JSONDecoder().decode(MissingComponents.self, from: Data(oversized.utf8))
        #expect(decoded.listed.count == 20)
        #expect(decoded.omitted == 30)
    }

    @Test func combiningMarksCannotSplitACredential() {
        let split = "ghp_\u{0301}ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"
        let message = GuesthouseError.toolMismatch(tool: "gh", found: SanitizedText(split), expected: "1").userMessage
        #expect(!message.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(message.contains("[redacted:github-token]"))
    }

    @Test func sanitizedTextLimitsSurviveARoundTrip() throws {
        let long = SanitizedText(String(repeating: "x", count: 100), limit: 200)
        #expect(long.value.unicodeScalars.count == 100)
        let decoded = try JSONDecoder().decode(SanitizedText.self, from: try JSONEncoder().encode(long))
        #expect(decoded == long)
        let capped = SanitizedText(String(repeating: "y", count: 5_000), limit: 100_000)
        #expect(capped.value.unicodeScalars.count == SanitizedText.maximumLimit + 1)
        let raw = try JSONDecoder().decode(SanitizedText.self, from: Data(("\"" + String(repeating: "z", count: 5_000) + "\"").utf8))
        #expect(raw.value.unicodeScalars.count == SanitizedText.maximumLimit + 1)
    }

    @Test func sanitizingAHugeValueCostsOnlyTheWindow() {
        let huge = String(repeating: "x", count: 20_000_000)
        let started = ContinuousClock.now
        _ = GuesthouseError.sanitize(huge)
        #expect(ContinuousClock.now - started < .milliseconds(200))
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
