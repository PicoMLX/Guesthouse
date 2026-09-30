import Synchronization
import Testing
@testable import GuesthouseRuntimeKit

struct OperationSupervisorTests {
    @Test func concurrentCompletionAndDeinitEndExactlyOnce() async {
        let trace = Mutex<[Int]>([])
        let supervisor = OperationSupervisor(begin: { trace.withLock { $0.append(1) } },
                                             finish: { trace.withLock { $0.append(-1) } })
        do {
            let token = supervisor.hold()
            #expect(trace.withLock { $0 } == [1])
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<32 { group.addTask { token.end() } }
            }
            #expect(trace.withLock { $0 } == [1, -1])
        }
        #expect(trace.withLock { $0 } == [1, -1])
    }

    @Test func independentOperationsKeepIndependentLifetimes() {
        let active = Mutex(0)
        let supervisor = OperationSupervisor(begin: { active.withLock { $0 += 1 } },
                                             finish: { active.withLock { $0 -= 1 } })
        let first = supervisor.hold()
        do {
            let second = supervisor.hold()
            #expect(active.withLock { $0 } == 2)
            first.end()
            #expect(active.withLock { $0 } == 1)
            withExtendedLifetime(second) {}
        } // Abandoning an unstarted token still balances the transaction.
        #expect(active.withLock { $0 } == 0)
        first.end()
        #expect(active.withLock { $0 } == 0)
    }
}
