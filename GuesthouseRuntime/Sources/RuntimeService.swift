import Foundation
import GuesthouseCore
import OSLog
import XPC

/// Decodes envelopes, dispatches named operations, and replies with `RuntimeEvent`s.
final class RuntimeService: Sendable {
    static let serviceName = "com.starlingprotocol.Guesthouse.Runtime"

    private let log = Logger(subsystem: serviceName, category: "service")

    /// One reply per request. Streaming events for long operations arrive with #25.
    func handle(_ message: XPCReceivedMessage) -> (any Encodable)? {
        let envelope: RuntimeRequestEnvelope
        do {
            envelope = try message.decode(as: RuntimeRequestEnvelope.self)
        } catch {
            // Never log the decoding error text: it can quote the raw offending value.
            log.error("undecodable request rejected")
            return RuntimeEvent.failed(OperationID(), .invalidRequest(.malformed))
        }
        do {
            try RequestValidator.validate(envelope)
        } catch {
            log.error("rejected request: \(error.guesthouseError.caseName, privacy: .public)")
            return RuntimeEvent.failed(OperationID(), error.guesthouseError)
        }
        switch envelope.request {
        case .runtimeVersion:
            return RuntimeEvent.runtimeVersion(Self.versionInfo)
        case .environmentStatus, .startEnvironment, .stopEnvironment, .importXcode, .cancelOperation:
            log.notice("operation not implemented yet: \(envelope.request.caseName, privacy: .public)")
            return RuntimeEvent.failed(OperationID(), .invalidRequest(.unsupportedOperation))
        }
    }

    func sessionEnded(_ error: XPCRichError) {
        // The rich error's description is opaque and may quote context; log a fixed message.
        log.notice("session ended")
    }

    static var versionInfo: RuntimeVersionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return RuntimeVersionInfo(
            serviceVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            serviceBuild: info["CFBundleVersion"] as? String ?? "0",
            protocolVersion: .current,
            tart: nil
        )
    }
}
