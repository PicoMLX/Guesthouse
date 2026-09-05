import Foundation
import Testing
@testable import GuesthouseCore

@Suite struct StorageSummarySafetyTests {
    private func summary(path: String) -> StorageSummary {
        StorageSummary(storageRootPath: path, runtimeDownloadEstimateBytes: 1,
                       restoreImageEstimateBytes: 2, guestDiskBytes: 3, firstSetupAllowanceBytes: 4)
    }

    private static let hostilePaths = [
        "/Volumes/ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab/Guesthouse",
        "/Volumes/AB12-CD34/Guesthouse",
        "/Volumes/Work\u{202E}\n\u{1B}[31m/Guesthouse",
        "/Volumes/" + String(repeating: "a", count: 2_000),
    ]

    private func expectSafe(_ path: String) {
        #expect(!path.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"))
        #expect(!path.contains("AB12-CD34"))
        #expect(!path.contains("\u{202E}"))
        #expect(!path.contains("\n"))
        #expect(!path.contains("\u{1B}"))
        #expect(path.unicodeScalars.count <= 401)
    }

    @Test(arguments: hostilePaths)
    func constructionSanitizesThePathBeforeEncoding(_ path: String) throws {
        let value = summary(path: path)
        let expected = GuesthouseError.sanitize(path, limit: 400)
        #expect(value.storageRootPath == expected)
        expectSafe(value.storageRootPath)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        #expect(json?["storageRootPath"] as? String == expected)
    }

    @Test(arguments: hostilePaths)
    func assignmentCannotBypassThePathBoundary(_ path: String) throws {
        var value = summary(path: "/Volumes/Work/Guesthouse")
        value.storageRootPath = path
        #expect(value.storageRootPath == GuesthouseError.sanitize(path, limit: 400))
        expectSafe(value.storageRootPath)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        #expect(json?["storageRootPath"] as? String == value.storageRootPath)
    }

    @Test(arguments: hostilePaths)
    func decodingSanitizesUntrustedPathStrings(_ path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "storageRootPath": path, "runtimeDownloadEstimateBytes": 1,
            "restoreImageEstimateBytes": 2, "guestDiskBytes": 3, "firstSetupAllowanceBytes": 4,
        ])
        let value = try JSONDecoder().decode(StorageSummary.self, from: data)
        #expect(value.storageRootPath == GuesthouseError.sanitize(path, limit: 400))
        expectSafe(value.storageRootPath)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        #expect(encoded?["storageRootPath"] as? String == value.storageRootPath)
        #expect(value.runtimeDownloadEstimateBytes == 1)
        #expect(value.restoreImageEstimateBytes == 2)
        #expect(value.guestDiskBytes == 3)
        #expect(value.firstSetupAllowanceBytes == 4)
    }

    @Test func inPlaceStringMutationsCannotBypassTheBoundary() throws {
        var value = summary(path: "/Volumes/Work/")
        value.storageRootPath.append("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab")
        expectSafe(value.storageRootPath)
        #expect(value.storageRootPath.contains("[redacted:github-token]"))

        value.storageRootPath = "/Volumes/Work/Guesthouse"
        let range = try #require(value.storageRootPath.range(of: "Work"))
        value.storageRootPath.replaceSubrange(range, with: "AB12-CD34")
        expectSafe(value.storageRootPath)
        #expect(value.storageRootPath.contains("[redacted:device-code]"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        #expect(json?["storageRootPath"] as? String == value.storageRootPath)
    }

    @Test func ordinaryPathsAndJSONShapeRemainCompatible() throws {
        let path = "/Users/dev/Library/Application Support/Guesthouse"
        let value = summary(path: path)
        #expect(value.storageRootPath == path)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(StorageSummary.self, from: data) == value)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["storageRootPath", "runtimeDownloadEstimateBytes", "restoreImageEstimateBytes", "guestDiskBytes", "firstSetupAllowanceBytes"])
        #expect(json["storageRootPath"] as? String == path)
    }
}
