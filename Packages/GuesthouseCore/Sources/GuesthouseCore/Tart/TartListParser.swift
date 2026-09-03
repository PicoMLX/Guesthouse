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
    /// The value is sanitized (redacted and bounded) before it is stored: it came from the CLI.
    case unknownValue(field: String, value: String)
    case notAnIPAddress
    case notAVersion
}

public enum TartListParser {
    /// Tart's field names, decoded strictly: a JSON boolean never becomes a number and a
    /// number never becomes a boolean, so a changed schema fails instead of producing
    /// plausible but wrong inventory.
    private struct RawEntry: Decodable {
        let Source: String
        let Name: String
        let Disk: Int
        let Size: Int
        let Accessed: String
        let Running: Bool
        let State: String
    }

    public static func parse(_ data: Data) throws(TartParseError) -> [TartVMInfo] {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw .notJSON }
        let entries: [RawEntry]
        do {
            entries = try JSONDecoder().decode([RawEntry].self, from: data)
        } catch let DecodingError.typeMismatch(_, context) {
            throw .unexpectedShape(context.codingPath.last?.stringValue ?? "expected an array of objects")
        } catch let DecodingError.keyNotFound(key, _) {
            throw .unexpectedShape(key.stringValue)
        } catch let DecodingError.valueNotFound(_, context) {
            throw .unexpectedShape(context.codingPath.last?.stringValue ?? "value")
        } catch {
            throw .unexpectedShape("expected an array of objects")
        }
        var result: [TartVMInfo] = []
        for entry in entries {
            // Exactly the two pinned spellings; any other casing is a changed schema.
            let source: TartVMInfo.Source
            switch entry.Source {
            case "local": source = .local
            case "OCI": source = .oci
            default: throw .unknownValue(field: "Source", value: GuesthouseError.sanitize(entry.Source))
            }
            guard !entry.Name.isEmpty else { throw .unexpectedShape("Name") }
            guard let state = TartVMInfo.State(rawValue: entry.State) else { throw .unknownValue(field: "State", value: GuesthouseError.sanitize(entry.State)) }
            guard entry.Disk >= 0 else { throw .unknownValue(field: "Disk", value: String(entry.Disk)) }
            guard entry.Size >= 0 else { throw .unknownValue(field: "Size", value: String(entry.Size)) }
            // The key is part of the pinned shape and must be present; only its value may fail
            // to parse, which is reported as `nil`.
            let accessed = try? Date(entry.Accessed, strategy: .iso8601)
            result.append(TartVMInfo(source: source, name: entry.Name, diskGigabytes: entry.Disk, sizeGigabytes: entry.Size, accessed: accessed, running: entry.Running, state: state))
        }
        return result
    }

    public static func parse(_ text: String) throws(TartParseError) -> [TartVMInfo] {
        try parse(Data(text.utf8))
    }
}
