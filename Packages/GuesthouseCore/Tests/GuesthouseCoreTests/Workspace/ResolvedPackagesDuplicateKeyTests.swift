import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct ResolvedPackagesDuplicateKeyTests {
    private let sha = String(repeating: "a", count: 40)
    private func pin(_ fields: String = "") -> String {
        #"{"identity":"library","kind":"remoteSourceControl","location":"https://github.com/Org/Library.git","state":{"revision":"\#(sha)"}\#(fields)}"#
    }
    private func decode(_ json: String) throws -> ResolvedPackagesFile {
        try ResolvedPackagesFile.decode(Data(json.utf8))
    }
    @Test func schemaAndPinsUseOneCodableKeySelection() throws {
        let file = try decode(#"{"version":2,"version":3,"originHash":false,"pins":[\#(pin())],"pins":[]}"#)
        #expect(file.version == 2 && file.pins.count == 1)
        #expect(throws: ResolvedPackagesError.malformed(.originHash)) {
            try decode(#"{"version":3,"version":2,"originHash":false,"pins":[]}"#)
        }
    }
    @Test func pinAndStateDuplicateKeysMatchSwiftPMsCodableSelection() throws {
        let duplicateFields = #", "identity":"other","kind":"registry","location":"elsewhere","state":{"version":"2.0.0"}"#
        let file = try decode(#"{"version":3,"pins":[\#(pin(duplicateFields))]}"#)
        #expect(file.pins[0].identity.rawValue == "library" && file.pins[0].kind == .remoteSourceControl)
        #expect(file.pins[0].location == "https://github.com/Org/Library.git" && file.pins[0].revision == sha)
        let state = #"{"revision":"\#(sha)","revision":"invalid","version":"1.2.3","version":"bad","branch":"main","branch":false}"#
        let nested = try decode(#"{"version":3,"pins":[{"identity":"library","kind":"remoteSourceControl","location":"https://github.com/Org/Library.git","state":\#(state)}]}"#)
        #expect(nested.pins[0].revision == sha && nested.pins[0].version == "1.2.3" && nested.pins[0].branch == "main")
    }
}
