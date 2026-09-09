import Foundation
import GuesthouseCore
import Testing

struct SemanticVersionTests {
    @Test(arguments: [
        ("26.5", [26, 5], "26.5"), ("26.5.0.0", [26, 5], "26.5"),
        ("00026.005.2", [26, 5, 2], "26.5.2"), ("0.0.0", [0], "0")
    ])
    func normalization(_ input: String, _ components: [Int], _ canonical: String) throws {
        let version = try #require(SemanticVersion(input))
        #expect(version.components == components)
        #expect(version.description == canonical)
        #expect(version == SemanticVersion(components))
        #expect(try JSONDecoder().decode(SemanticVersion.self, from: JSONEncoder().encode(version)) == version)
    }

    @Test(arguments: [
        "", ".", "26.", ".26", "26..4", "-1", "-0", "+26", "26.+4", " 26.4",
        "26.4 ", "26.4\n", "v26.4", "26.4-beta", "26.4+1", "２６.４", "syntheticOpaque",
        "9999999999999999999999999999999999999999999"
    ])
    func unknownInputIsRejectedWithoutEchoingIt(_ input: String) throws {
        #expect(SemanticVersion(input) == nil)
        let data = try JSONEncoder().encode(input)
        do {
            _ = try JSONDecoder().decode(SemanticVersion.self, from: data)
            Issue.record("An invalid numeric version decoded successfully")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.debugDescription == "not a supported dotted numeric version")
            #expect(context.underlyingError == nil)
        }
    }

    @Test func observationsAreBoundedBeforeSplitting() {
        #expect(SemanticVersion.maximumInputLength == 256)
        let atLimit = String(repeating: "0.", count: 127) + "00"
        #expect(SemanticVersion(atLimit) == SemanticVersion([0]))
        #expect(SemanticVersion(atLimit + "0") == nil)
    }

    @Test(arguments: [("26.4", "26.5"), ("2.9", "2.10"), ("1", "1.0.1"), ("0", "1")])
    func orderingIsNumeric(_ lower: String, _ higher: String) throws {
        let lhs = try #require(SemanticVersion(lower))
        let rhs = try #require(SemanticVersion(higher))
        #expect(lhs < rhs)
        #expect(!(rhs < lhs))
    }

    @Test func equalVersionsHaveTheSameHashIdentity() {
        #expect(Set([SemanticVersion([26, 4]), SemanticVersion([26, 4, 0])]).count == 1)
        #expect(SemanticVersion([]) == SemanticVersion([0]))
    }

    @Test(arguments: [("26.3", false), ("26.4", true), ("26.5", true), ("26.6", false)])
    func rangesIncludeBothEndpoints(_ input: String, _ expected: Bool) throws {
        let range = VersionRange(minimum: SemanticVersion([26, 4]), maximum: SemanticVersion([26, 5]))
        #expect(range.contains(try #require(SemanticVersion(input))) == expected)
        #expect(try JSONDecoder().decode(VersionRange.self, from: JSONEncoder().encode(range)) == range)
    }

    @Test func openEndedRangesAndInvalidWireBounds() throws {
        let range = VersionRange(minimum: SemanticVersion([26, 4]))
        #expect(range.contains(SemanticVersion([99])))
        #expect(!range.contains(SemanticVersion([26, 3])))
        #expect(try JSONDecoder().decode(VersionRange.self, from: JSONEncoder().encode(range)) == range)
        let invalid = Data(#"{"minimum":"26.5","maximum":"26.4"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(VersionRange.self, from: invalid) }
    }
}
