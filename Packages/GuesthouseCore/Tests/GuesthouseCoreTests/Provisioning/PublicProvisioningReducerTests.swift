import GuesthouseCore
import Testing

/// This file deliberately uses an ordinary import: the pure reducer must be usable by a
/// coordinator without exposing runtime execution or relying on test-only access.
@Suite struct PublicProvisioningReducerTests {
    @Test func reservingAndAcceptingAStartUsesThePublicContract() throws {
        let reserved = try ProvisioningReducer.reduce(.initial, .startRequested(stage: .first))
        let request = try #require(reserved.state.status.pendingEffect)
        #expect(reserved.state.status == .startRequested(request: request, resuming: nil))
        #expect(reserved.effects.isEmpty)
        let operation = OperationID()
        let accepted = try ProvisioningReducer.reduce(
            reserved.state, .operationStarted(operation, stage: .first, request: request)
        )
        #expect(accepted.state.status == .inProgress(operation))
        #expect(accepted.effects.isEmpty)
        // This API returns descriptions only; an interruption requests inspection, not execution.
        let interrupted = try ProvisioningReducer.reduce(accepted.state, .connectionInterrupted(operation))
        let inspection = try #require(interrupted.state.status.pendingEffect)
        #expect(interrupted.effects == [.inspectActualState(.first, inspection, operation: operation)])
    }
}
