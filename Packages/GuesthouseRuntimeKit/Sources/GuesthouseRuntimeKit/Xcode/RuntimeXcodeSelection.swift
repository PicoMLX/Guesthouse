import Darwin
import GuesthouseCore
import XPC

/// Owns one authenticated native grant, never a GUI-supplied path. Duplication happens
/// after frame/request validation; filesystem reads happen only on the bounded worker.
final class RuntimeXcodeSelection: Sendable {
    private let descriptor: Int32
    private let matchesExpectedBundle: Bool
    private init(taking descriptor: Int32, matchesExpectedBundle: Bool) {
        self.descriptor = descriptor; self.matchesExpectedBundle = matchesExpectedBundle
    }
    deinit { close(descriptor) }

    static func bind(_ request: RuntimeRequest, message: XPCDictionary) throws(GuesthouseError) -> RuntimeXcodeSelection? {
        let result: Result<RuntimeXcodeSelection?, GuesthouseError> = message.withUnsafeUnderlyingDictionary { dictionary in
            let grant = xpc_dictionary_get_value(dictionary, "selectedDirectory")
            guard case .inspectXcode(let handoff) = request else {
                guard grant == nil else { return .failure(.invalidRequest(.malformed)) }
                return .success(nil)
            }
            guard case .fileDescriptor = handoff.kind,
                  let grant, xpc_get_type(grant) == XPC_TYPE_FD else { return .failure(.invalidRequest(.malformed)) }
            let descriptor = xpc_dictionary_dup_fd(dictionary, "selectedDirectory")
            guard descriptor >= 0 else { return .failure(.invalidRequest(.malformed)) }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                close(descriptor)
                return .failure(.invalidRequest(.malformed))
            }
            return .success(RuntimeXcodeSelection(taking: descriptor,
                matchesExpectedBundle: handoff.expectedBundleIdentifier == nil || handoff.expectedBundleIdentifier == "com.apple.dt.Xcode"))
        }
        return try result.get()
    }

    func inspect(isCanceled: @Sendable () -> Bool) -> RuntimeEvent {
        guard !isCanceled(), fcntl(descriptor, F_GETFL) & O_ACCMODE == O_RDONLY else {
            return .xcodeSelection(.rejected(.unavailable))
        }
        guard matchesExpectedBundle else { return .xcodeSelection(.rejected(.notXcode)) }
        do { return .xcodeSelection(.candidate(try XcodeBundleInspection.candidate(borrowing: descriptor, isCanceled: isCanceled))) }
        catch { return .xcodeSelection(.rejected(error)) }
    }
}
