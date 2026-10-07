import Foundation
import GuesthouseCore

/// Historical #83/#86 identity retained while migrating the read-only verifier (MVP §3).
/// This artifact remains REJECTED by strict signature validation; it must never be launched.
/// No production provider is selected. A reviewed candidate update is separate from this
/// migration and still cannot establish human preflight or hardware-gate results.
enum LumePin {
    static let version = SemanticVersion([0, 5, 3])
    static let releaseTag = "lume-v0.5.3"
    static let archiveName = "lume-0.5.3-darwin-arm64.tar.gz"
    static let archiveSHA256 = "af5d0556763a7f0116153c220aaabe44974e775091ac57e38da2abb2959c63e8"
    static let downloadURL = URL(string: "https://github.com/trycua/cua/releases/download/\(releaseTag)/\(archiveName)")!
    /// Canonical 20-byte CDHash derived from the official arm64 bundle's SHA-256 CodeDirectory.
    /// Unlike its unsealed Info.plist version, this binds discovery to the code we measured.
    static let codeDirectoryHash = "320e86c91aefaf7e283bde6560a699c44e931c2d"
    static let executableSHA256 = "82941bf535f8bebb469f6bd5c9b5cfbecee18fec8a34a99589d433f6b2989705"
    static let bundleName = "lume.app"
    static let executableName = "lume"
    static let bundleIdentifier = "com.trycua.lume"
    static let teamIdentifier = "YCK386LBJ7"
    static let requiredEntitlements = ["com.apple.security.virtualization", "com.apple.vm.networking"]
    static let codeRequirement = #"identifier "com.trycua.lume" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "YCK386LBJ7""#
}
