import Foundation
import GuesthouseCore

/// Exact official release evaluated by the Phase-0 spike. Recorded from the `lume-v0.5.3`
/// GitHub release and a fresh download on 2026-09-03. Updating any value requires a new
/// hardware record; current web documentation is not evidence about an older binary.
public enum LumePin {
    public static let version = SemanticVersion([0, 5, 3])
    public static let releaseTag = "lume-v0.5.3"
    public static let archiveName = "lume-0.5.3-darwin-arm64.tar.gz"
    public static let archiveSHA256 = "af5d0556763a7f0116153c220aaabe44974e775091ac57e38da2abb2959c63e8"
    public static let downloadURL = URL(string: "https://github.com/trycua/cua/releases/download/\(releaseTag)/\(archiveName)")!
    /// Canonical 20-byte CDHash derived from the official arm64 bundle's SHA-256 CodeDirectory.
    /// Unlike its unsealed Info.plist version, this binds discovery to the code we measured.
    public static let codeDirectoryHash = "320e86c91aefaf7e283bde6560a699c44e931c2d"
    public static let executableSHA256 = "82941bf535f8bebb469f6bd5c9b5cfbecee18fec8a34a99589d433f6b2989705"
    public static let bundleName = "lume.app"
    public static let executableName = "lume"
    public static let bundleIdentifier = "com.trycua.lume"
    public static let teamIdentifier = "YCK386LBJ7"
    public static let requiredEntitlements = ["com.apple.security.virtualization", "com.apple.vm.networking"]
    public static let codeRequirement = #"identifier "com.trycua.lume" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "YCK386LBJ7""#
}
