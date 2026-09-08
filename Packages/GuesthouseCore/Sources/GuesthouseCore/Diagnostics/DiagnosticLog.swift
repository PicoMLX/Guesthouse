import Foundation

/// Bounded session history, shared by the UI and export builder. Not a raw-output buffer.
/// The owning actor serializes mutations. Cross-session persistence is deferred (#91).
public struct DiagnosticLog: Sendable {
    public struct Record: Encodable, Hashable, Sendable {
        public let recordedAt: Date
        public let event: DiagnosticEvent
    }

    public static let maximumCapacity = 2_000
    public let capacity: Int
    public private(set) var records: [Record] = []
    public private(set) var discardedCount: UInt64 = 0

    public init(capacity: Int = 256) {
        self.capacity = min(max(capacity, 0), Self.maximumCapacity)
    }

    public mutating func append(_ event: DiagnosticEvent, recordedAt: Date = Date()) {
        if records.count == capacity {
            if discardedCount < .max { discardedCount += 1 }
            guard capacity > 0 else { return }
            records.removeFirst()
        }
        records.append(Record(recordedAt: recordedAt, event: event))
    }

    public mutating func removeAll() {
        records.removeAll()
        discardedCount = 0
    }

    /// Export only typed records. Never attach an error description on encoding failure.
    public func jsonData() throws -> Data {
        struct Export: Encodable {
            let schemaVersion = 1
            let discardedCount: UInt64
            let records: [Record]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Export(discardedCount: discardedCount, records: records))
    }

    public var text: String {
        let header = "Guesthouse structured diagnostics. Raw process and authentication output excluded."
        let lines = records.map { record in
            let event = record.event
            return "[\(event.operationID)] "
                + (event.environmentID.map { "environment=\($0) " } ?? "")
                + event.message
                + (event.recoveryMessage.map { " Recovery: " + $0 } ?? "")
        }
        return ([header, "Older/omitted events: \(discardedCount)."] + lines).joined(separator: "\n")
    }
}
