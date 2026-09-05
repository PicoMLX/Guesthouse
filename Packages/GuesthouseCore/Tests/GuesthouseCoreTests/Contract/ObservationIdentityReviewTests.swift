import Foundation
import Testing
@testable import GuesthouseCore

struct ObservationIdentityReviewTests {
    @Test(arguments: ["password: sampleOne", "password: sampleTwo",
                      "\u{1B}]AB12-CD34\u{07}"])
    func decodedSecretObservationsAreUnknown(input: String) throws {
        var raw = ObservedTuple(RuntimeContractHardeningTests.knownTuple)
        raw.codexCLIPath = input
        raw.codexCLICapabilities = ["normal", input]
        let decoded = try JSONDecoder().decode(ObservedTuple.self, from: JSONEncoder().encode(raw))
        #expect(decoded.codexCLIPath == nil)
        #expect(decoded.codexCLICapabilities == nil)
        #expect(decoded.exact == nil)
        #expect(decoded.unknownFields.contains(.codexCLIPath))
        #expect(decoded.unknownFields.contains(.codexCLICapabilities))
    }

    @Test func identitiesRetainTheFullSHA256Digest() {
        #expect(ObservedTuple.digest(of: "abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ObservedTuple.digest(ofList: ["one", "two"]).count == 64)
        let value = String(repeating: "a", count: 400)
        let bounded = ObservedTuple.bounded(value, limit: 256)
        #expect(bounded?.hasSuffix("[exact:\(ObservedTuple.digest(of: value))]") == true)
        #expect((bounded?.unicodeScalars.count ?? 0) <= 256)
        #expect(ObservedTuple.identitySuffixLength == " [exact:".count + 64 + "]…".count)
    }

    @Test(arguments: ["0.50.0\u{1B}[31m", String(repeating: "a", count: 257)])
    func decodingDoesNotSilentlyChangeAnObservationIdentity(input: String) throws {
        let raw = ObservedTuple(codexCLIVersion: input)
        let decoded = try JSONDecoder().decode(ObservedTuple.self, from: JSONEncoder().encode(raw))
        #expect(decoded.codexCLIVersion == nil)
        let sanitized = raw.sanitizedForWire()
        let roundTrip = try JSONDecoder().decode(ObservedTuple.self, from: JSONEncoder().encode(sanitized))
        #expect(roundTrip == sanitized, "the sender's safe exact identity survives unchanged")
    }
}
