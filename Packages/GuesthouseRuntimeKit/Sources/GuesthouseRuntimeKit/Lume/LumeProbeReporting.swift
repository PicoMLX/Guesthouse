import GuesthouseCore
import Synchronization

/// Typed report construction only. Reuses DiagnosticLog; no launch/verification authority,
/// exception-string classifier or second runner/store. Only StateStore supplies production work.
enum LumeProbeReporting {
    static func capture(
        probe: @Sendable (@escaping @Sendable (DiagnosticEvent) -> Void) async throws -> RuntimeProbeAdvertisement
    ) async -> RuntimeProbeReport {
        let log = Mutex(DiagnosticLog(capacity: RuntimeProbeReport.maximumDiagnosticCount))
        let advertisements: RuntimeProbeAdvertisement?, failure: RuntimeProbeFailure?
        do {
            try Task.checkCancellation()
            let value = try await probe { event in log.withLock { $0.append(event) } }
            try Task.checkCancellation()
            advertisements = value; failure = nil
        }
        catch { advertisements = nil; failure = classify(error) }
        let (events, dropped) = log.withLock { ($0.records.map(\.event), $0.discardedCount) }
        let result = RuntimeProbeReport(advertisements: advertisements, failure: failure, diagnostics: events)
        // Never export a partial/foreign trace as a complete report or manufacture an ID.
        guard dropped == 0, result.isValid else {
            return RuntimeProbeReport(failure: .outcomeUnknown, diagnostics: [])
        }
        return result
    }

    static func classify(_ error: any Error) -> RuntimeProbeFailure {
        switch error {
        case LumeVerificationError.bundleMissing: .runtimeMissing
        case is LumeVerificationError: .verificationFailed
        case let error as LumeProbeResponseFailure:
            switch error {
            case .interrupted: .outcomeUnknown
            case .timedOut: .timedOut
            case .processFailed(let status): .processFailed(exitStatus: status)
            case .invalidResponse: .invalidResponse
            case .versionMismatch: .versionMismatch
            }
        case is LumeLaunchOwnershipFailure: .inspectionRequired
        case StorageFailure.inspectionFailed: .storageUnavailable
        case is StorageFailure, StateStoreError.insecureDirectory: .unsafeStorage
        case is StateStoreError: .storageUnavailable
        default: .outcomeUnknown // Includes requested cancellation, not confirmed cleanup.
        }
    }
}
