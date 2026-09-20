import Foundation

/// Pure message checks, not caller authentication, per-session admission, or file authority.
public enum RequestValidator: Sendable {
    public static let maximumEncodedSize = 64 * 1024
    public static let maximumBookmarkSize = 16 * 1024
    public static let maximumDisplayNameLength = 255
    public static let maximumBundleIdentifierSize = 255
    public static let maximumIPWait: Duration = .seconds(300)
    public static let maximumGracefulStopDeadline: Duration = .seconds(600)

    /// Required entry point for transport bytes: size → version → payload → option bounds.
    /// Never forward an underlying decoder error, coding path, or input snippet to diagnostics.
    public static func decode(_ data: Data) throws(RequestValidationError) -> RuntimeRequestEnvelope {
        try validateEncodedSize(data)
        do {
            let envelope = try JSONDecoder().decode(RuntimeRequestEnvelope.self, from: data)
            try validate(envelope)
            return envelope
        } catch let error as RuntimeRequestEnvelope.ProtocolMismatch {
            throw .protocolMismatch(client: error.client, service: .current)
        } catch let error as RequestValidationError {
            throw error
        } catch {
            throw .malformed
        }
    }

    public static func validateEncodedSize(_ data: Data) throws(RequestValidationError) {
        guard data.count <= maximumEncodedSize else {
            throw .oversized(bytes: data.count, limit: maximumEncodedSize)
        }
    }

    public static func validate(_ envelope: RuntimeRequestEnvelope) throws(RequestValidationError) {
        guard envelope.protocolVersion == .current else {
            throw .protocolMismatch(client: envelope.protocolVersion, service: .current)
        }
        switch envelope.request {
        case .runtimeVersion, .hostPreflight, .environmentStatus, .cancelOperation, .stopEnvironment(_, .force): break
        case .startEnvironment(_, let options):
            guard options.ipWait >= .zero, options.ipWait <= maximumIPWait else {
                throw .optionOutOfRange(.ipWait)
            }
        case .stopEnvironment(_, .graceful(let deadline)):
            guard deadline > .zero, deadline <= maximumGracefulStopDeadline else {
                throw .optionOutOfRange(.gracefulStopDeadline)
            }
        case .importXcode(_, let handoff): try validate(handoff)
        }
    }

    public static func validate(_ handoff: FileHandoff) throws(RequestValidationError) {
        if case .securityScopedBookmark(let data) = handoff.kind {
            guard !data.isEmpty else { throw .invalidHandoff }
            guard data.count <= maximumBookmarkSize else {
                throw .oversized(bytes: data.count, limit: maximumBookmarkSize)
            }
        }
        let name = handoff.displayName
        guard !name.isEmpty, name.utf8.count <= maximumDisplayNameLength * 4,
              name.unicodeScalars.count <= maximumDisplayNameLength,
              name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator: true
                  default: false
                  }
              }) else { throw .invalidDisplayName }
        if let identifier = handoff.expectedBundleIdentifier {
            guard !identifier.isEmpty, identifier.utf8.count <= maximumBundleIdentifierSize,
                  identifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                      || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                  identifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty })
            else { throw .invalidBundleIdentifier }
        }
    }
}

public enum RequestValidationError: Error, Hashable, Sendable {
    public enum Option: Hashable, Sendable { case ipWait, gracefulStopDeadline }
    case oversized(bytes: Int, limit: Int)
    case protocolMismatch(client: RuntimeProtocolVersion, service: RuntimeProtocolVersion)
    case optionOutOfRange(Option)
    case invalidDisplayName, invalidBundleIdentifier, invalidHandoff, malformed
    case invalidVMName, invalidPath, pathEscapesRoot

    public var guesthouseError: GuesthouseError {
        switch self {
        case .oversized: .invalidRequest(.oversized)
        case .protocolMismatch(let client, let service):
            .protocolMismatch(client: client.rawValue, service: service.rawValue)
        case .invalidVMName: .invalidRequest(.invalidVMName)
        case .pathEscapesRoot: .invalidRequest(.pathEscapesAllowedRoot)
        case .optionOutOfRange, .invalidDisplayName, .invalidBundleIdentifier, .invalidHandoff, .invalidPath, .malformed:
            .invalidRequest(.malformed)
        }
    }
}
