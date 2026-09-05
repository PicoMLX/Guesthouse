import Foundation
import GuesthouseCore
import OSLog
import XPC

/// The service's only log sink.
///
/// It accepts `RedactedLine` and nothing else, so a diagnostic built from guest, CLI, or
/// request text cannot reach the system log unredacted (MVP-PLAN.md §3, "Local storage"). The
/// text is written as public on purpose: it has already passed the redaction layer, and hiding
/// it would only make a line that is safe to read unreadable in a diagnostics report.
struct ServiceLog: Sendable {
    private let log: Logger

    init(category: String) {
        log = Logger(subsystem: RuntimeService.serviceName, category: category)
    }

    func error(_ line: RedactedLine) { log.error("\(line.text, privacy: .public)") }
    func notice(_ line: RedactedLine) { log.notice("\(line.text, privacy: .public)") }
}

/// Decodes envelopes, dispatches named operations, and replies with `RuntimeEvent`s.
final class RuntimeService: Sendable {
    static let serviceName = "com.starlingprotocol.Guesthouse.Runtime"

    private let log = ServiceLog(category: "service")

    /// A diagnostic that carries a value, as a line the sink accepts.
    ///
    /// The values interpolated today are the service's own case names and protocol numbers,
    /// but they go through `Redactor` like any other text, so a line built later from guest,
    /// CLI, or request data cannot reach the log unredacted.
    private static func line(_ message: StaticString, _ value: String) -> RedactedLine {
        var state = Redactor.StreamState()
        return Redactor().redact(line: "\(message) \(value)", state: &state)
    }

    /// One reply per request. Streaming events for long operations arrive with #25.
    func handle(_ message: XPCReceivedMessage) -> RuntimeEvent {
        let envelope: RuntimeRequestEnvelope
        do {
            envelope = try message.decode(as: RuntimeRequestEnvelope.self)
        } catch let mismatch as RuntimeRequestEnvelope.ProtocolMismatch {
            // A version-skewed installation is not corrupt input: the client gets the
            // protocol-mismatch error and its reinstall recovery.
            log.error(Self.line("protocol mismatch: client", "\(mismatch.client.rawValue)"))
            return RuntimeEvent.failed(OperationID(), mismatch.error)
        } catch {
            // Never log the decoding error text: it can quote the raw offending value.
            log.error(RedactedLine(literal: "undecodable request rejected"))
            return RuntimeEvent.failed(OperationID(), .invalidRequest(.malformed))
        }
        do {
            try RequestValidator.validate(envelope)
        } catch {
            log.error(Self.line("rejected request:", error.guesthouseError.caseName))
            return RuntimeEvent.failed(OperationID(), error.guesthouseError)
        }
        switch envelope.request {
        case .runtimeVersion:
            return RuntimeEvent.runtimeVersion(Self.versionInfo)
        case .environmentStatus, .startEnvironment, .stopEnvironment, .importXcode, .cancelOperation:
            log.notice(Self.line("operation not implemented yet:", envelope.request.caseName))
            return RuntimeEvent.failed(OperationID(), .invalidRequest(.unsupportedOperation))
        }
    }

    func sessionEnded(_ error: XPCRichError) {
        // The rich error's description is opaque and may quote context; log a fixed message.
        log.notice(RedactedLine(literal: "session ended"))
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
