import Foundation
import GuesthouseCore
import Testing

@Suite struct SnapshotVersionAmbiguityTests {
    @Test(arguments: [
        #"{"schemaVersion":1,"schemaVersion":2}"#,
        #"{"schemaVersion":2,"schemaVersion":1}"#,
        #"{"schemaVersion":2,"schemaVersion":2}"#,
        #"{"schemaVersion":3,"schemaVersion":2}"#,
        #"{"schemaVersion":2,"schema\u0056ersion":1}"#,
        #"{"schema\u0056ersion":1,"schemaVersion":2}"#,
    ], [false, true])
    func duplicateVersionsAreRefusedAtInputAndAfterATransform(json: String, transformOutput: Bool) {
        let document = Data(json.utf8)
        let migrator = SnapshotMigrator(migrations: [
            .init(from: SchemaVersion(1)!) { _ in
                #expect(transformOutput, "An ambiguous input must be rejected before any transform.")
                return document
            },
        ])
        let input = transformOutput ? Data(#"{"schemaVersion":1}"#.utf8) : document
        #expect(throws: StateStoreError.corruptSnapshot) { try migrator.migrate(input) }
    }

    @Test(arguments: [
        #"{"schemaVersion":2,"nested":{"schemaVersion":1},"list":[{"schemaVersion":3}]}"#,
        #"{"nested":{"schemaVersion":1},"schema\u0056ersion":2}"#,
        #"{"text":"\"schemaVersion\":1,{}[]","schemaVersion":2}"#,
        #"{"schemaVersion":2,"text":"trailing\\","next":"value"}"#,
        #"{"schemaVersion":2,"schemaVersionSuffix":1}"#,
    ])
    func nestedKeysAndQuotedTextDoNotCreateEnvelopeMembers(json: String) throws {
        let source = Data(json.utf8)
        let migrated = try SnapshotMigrator.standard.migrate(source)
        #expect(migrated.from == SchemaVersion(2))
        #expect(migrated.data == source)
    }

    @Test func nestedVersionDoesNotVersionTheEnvelope() {
        let source = Data(#"{"nested":{"schemaVersion":2}}"#.utf8)
        #expect(throws: StateStoreError.migrationMissing(from: .unversioned)) {
            try SnapshotMigrator.standard.migrate(source)
        }
    }

    @Test(arguments: [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian])
    func nonUTF8MetadataIsRefusedWithoutTranscoding(encoding: String.Encoding) throws {
        let source = try #require(#"{"schemaVersion":2}"#.data(using: encoding))
        #expect(throws: StateStoreError.corruptSnapshot) { try SnapshotMigrator.standard.migrate(source) }
    }
}
