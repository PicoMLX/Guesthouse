import Foundation
import GuesthouseCore

/// Facts about the pinned Tart release, recorded from the official 2.36.0 artifacts
/// (MVP-PLAN.md §4, "Runtime delivery and console": verify the expected digest and signing
/// identity of the complete official bundle).
///
/// Recorded on 2026-09-03 from `https://github.com/openai/tart/releases/download/2.36.0/`:
/// the digest is the `tart.tar.gz` line of `tart_2.36.0_checksums.txt` and matched a fresh
/// download; the Team ID, signing identifier, and bundle name come from `codesign -dv` on
/// the extracted bundle (`Developer ID Application: Cirrus Labs, Inc. (9M2P8L4D89)`).
public enum TartRelease {
    public static let version = TartPin.version
    public static let archiveName = "tart.tar.gz"
    public static let archiveSHA256 = "c72a8ab8d78a6498a1e42688b1a1ec6c512ce46ca35a3a3be130c3de1440c7e8"
    public static let downloadURL = URL(string: "https://github.com/openai/tart/releases/download/\(TartPin.releaseTag)/tart.tar.gz")!
    public static let teamIdentifier = "9M2P8L4D89"
    public static let signingIdentifier = "com.github.cirruslabs.tart"
    /// The bundle inside the archive is lowercase `tart.app`.
    public static let bundleName = "tart.app"
    public static let executableName = "tart"
    /// Entitlements the runtime must carry to run macOS guests at all.
    public static let requiredEntitlements = ["com.apple.security.virtualization"]

    /// Designated requirement for the bundle: Developer ID signed by the recorded team with the
    /// recorded identifier. Same form Apple documents for Developer ID applications.
    public static var codeRequirement: String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(signingIdentifier)\""
    }
}
