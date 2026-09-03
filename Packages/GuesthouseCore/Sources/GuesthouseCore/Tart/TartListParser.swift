import Foundation

/// One entry of `tart list --format json` as produced by Tart 2.36.0.
///
/// Shape, from `Sources/tart/Commands/List.swift` at tag 2.36.0: `Source` ("local" or "OCI"),
/// `Name`, `Disk` and `Size` as whole gigabytes (the byte count divided by 1000³), `Accessed`
/// as an ISO 8601 timestamp in JSON mode, `Running`, and `State` (`running`, `suspended`,
/// `stopped`). A different Tart release may change this; the version is pinned for that reason.
public struct TartVMInfo: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        case local
        case oci
    }

    public enum State: String, Hashable, Sendable {
        case running
        case suspended
        case stopped
    }

    public let source: Source
    public let name: String
    public let diskGigabytes: Int
    public let sizeGigabytes: Int
    /// `nil` when Tart printed something that is not an ISO 8601 timestamp.
    public let accessed: Date?
    public let running: Bool
    public let state: State

    public init(source: Source, name: String, diskGigabytes: Int, sizeGigabytes: Int, accessed: Date?, running: Bool, state: State) {
        self.source = source
        self.name = name
        self.diskGigabytes = diskGigabytes
        self.sizeGigabytes = sizeGigabytes
        self.accessed = accessed
        self.running = running
        self.state = state
    }
}

public enum TartParseError: Error, Hashable, Sendable {
    case notJSON
    case unexpectedShape(String)
    case unknownValue(field: String, value: String)
    case notAnIPAddress
    case notAVersion
}

public enum TartListParser {
    public static func parse(_ data: Data) throws(TartParseError) -> [TartVMInfo] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw .notJSON }
        guard let entries = object as? [[String: Any]] else { throw .unexpectedShape("expected an array of objects") }
        var result: [TartVMInfo] = []
        for entry in entries {
            result.append(try parseEntry(entry))
        }
        return result
    }

    public static func parse(_ text: String) throws(TartParseError) -> [TartVMInfo] {
        try parse(Data(text.utf8))
    }

    private static func parseEntry(_ entry: [String: Any]) throws(TartParseError) -> TartVMInfo {
        guard let sourceRaw = entry["Source"] as? String else { throw .unexpectedShape("Source") }
        guard let source = TartVMInfo.Source(rawValue: sourceRaw.lowercased()) else { throw .unknownValue(field: "Source", value: sourceRaw) }
        guard let name = entry["Name"] as? String, !name.isEmpty else { throw .unexpectedShape("Name") }
        guard let disk = entry["Disk"] as? Int else { throw .unexpectedShape("Disk") }
        guard let size = entry["Size"] as? Int else { throw .unexpectedShape("Size") }
        guard let running = entry["Running"] as? Bool else { throw .unexpectedShape("Running") }
        guard let stateRaw = entry["State"] as? String else { throw .unexpectedShape("State") }
        guard let state = TartVMInfo.State(rawValue: stateRaw) else { throw .unknownValue(field: "State", value: stateRaw) }
        let accessed = (entry["Accessed"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return TartVMInfo(source: source, name: name, diskGigabytes: disk, sizeGigabytes: size, accessed: accessed, running: running, state: state)
    }
}
