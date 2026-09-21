import GuesthouseCore
import GuesthouseRuntimeKit
import Testing

@Test func stateStorePublicAPIIsSendableAndSelectsItsOwnStorage() {
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(StateStore.self)
    // Compile the ordinary-import public API without invoking real Application Support IO.
    let factory: @Sendable () async throws(StateStoreError) -> StateStore = StateStore.open
    _ = factory
}
