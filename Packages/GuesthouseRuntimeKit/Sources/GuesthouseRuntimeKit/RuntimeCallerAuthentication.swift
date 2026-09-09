import GuesthouseRuntimeAuthentication
import XPC

/// Fixed host-app identity policy for #20/#112 and MVP-PLAN.md §3. No endpoint is activated.
public enum RuntimeCallerAuthentication: Sendable {
    /// Apply when creating the service listener. Per-message checks below remain mandatory.
    public static var listenerRequirement: XPCPeerRequirement {
        .isFromSameTeam(andMatchesSigningIdentifier: GHRGuesthouseSigningIdentifier)
    }

    /// Check the ORIGINAL received dictionary before framing, decoding or reply-context
    /// consumption, including one-way messages. Do not reconstruct it from client fields.
    /// The service still owns refusal, bounded admission, registration and reply accounting;
    /// true does not authorize arbitrary operations or prove their eventual outcomes.
    public static func allows(_ receivedMessage: XPCDictionary) -> Bool {
        receivedMessage.withUnsafeUnderlyingDictionary(GHRMessageSenderIsGuesthouse)
    }
}
