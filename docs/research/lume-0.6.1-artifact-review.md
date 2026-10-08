# Lume 0.6.1 static artifact review

Lume 0.6.1 passes the static checks below for these exact downloaded bytes on an arm64 Mac running macOS 26.6.2 (25G83). Recorded October 5, 2026 (UTC), after the official release on October 4 at 18:47:46 UTC. Operator: Codex, the automated assistant in this Guesthouse chat, performed the downloads, bounded extraction and static checks. No provider executable, launcher wrapper or installer was run, no runtime was installed, and no production pin or provider was adopted.

This is candidate artifact evidence for [issue #82](https://github.com/PicoMLX/Guesthouse/issues/82), [ADR 0002](../decisions/0002-prioritize-lume-and-shared-infrastructure.md) and [MVP-PLAN.md](../../MVP-PLAN.md) §§3, 10, indexed by the [canonical feasibility record](provider-feasibility.md). It does not establish signed-XPC execution, guest Codex connectivity, native MLX/GPU behavior, provider acceptance or a phase-zero hardware result. The [0.6.0 record](lume-0.6.0-artifact-review.md) remains historical evidence; the earlier 0.5.3 artifact remains rejected.

## Official source and measured identities

- [Release and checksums](https://github.com/trycua/cua/releases/tag/lume-v0.6.1).
- [Versioned arm64 app archive](https://github.com/trycua/cua/releases/download/lume-v0.6.1/lume-0.6.1-darwin-arm64.tar.gz).
- [Versioned installer archive](https://github.com/trycua/cua/releases/download/lume-v0.6.1/lume-0.6.1-darwin-arm64.pkg.tar.gz).
- [Release manifest](https://github.com/trycua/cua/releases/download/lume-v0.6.1/release-manifest.json): source revision `3350f504014c85416009a90fcb339fe556ce02fc`.

The downloaded archives matched both the release API asset sizes/digests and the manifest. The manifest's downloaded bytes matched its release API size/digest. Extraction stayed in private temporary storage with at most 128 entries, 32 MiB per entry and 64 MiB total expanded data per archive; absolute/traversing names, links, special files and duplicate paths were rejected. The app archive contains 16 entries totaling 21,672,262 expanded bytes, including the separate launcher wrapper and `lume.app`. The installer archive contains only the 6,133,072-byte `lume.pkg`. Static app checks targeted `lume.app`.

| Item | Measured value |
| --- | --- |
| App archive bytes / SHA-256 | 6,112,964 / `2675b7981b7d3eb525cd27f40a385c986052eb71b3360c0b2579644725f1bad8` |
| Installer archive bytes / SHA-256 | 6,054,365 / `6ef6a709a07d4ba7ad952c22eacf115b105e654b880feced80202d1b8f678708` |
| Manifest bytes / SHA-256 | 3,008 / `35942ca88cf0a0eee5aabbf7e73d004def542f8232b553c00daddf1e9aa05654` |
| `lume.app/Contents/MacOS/lume` SHA-256 | `a369d63746690afe79626e357241df2f95b523e7f6f60ac9bc7665762abfc904` |
| CodeDirectory hash | `ff81723c61a4a233b221fac03afb58daf00d5c34` |
| Bundle and signing identifier | `com.trycua.lume` |
| Bundle version / executable | `0.6.1` / `lume` |
| Architecture / signing | arm64 / Hardened Runtime, Developer ID Application |
| Team identifier | `YCK386LBJ7` |
| Entitlements | `com.apple.security.virtualization=true`, `com.apple.vm.networking=true`; no additional entitlement keys |

## Static checks performed

A trusted local Swift probe compiled with Swift 6 and warnings as errors applied the retained #83/#86 verifier's exact Security.framework flags and Developer ID requirement to the downloaded app. All check processes exited successfully; the trusted probe compilation emitted no warnings.

| Check | Result |
| --- | --- |
| `SecStaticCodeCreateWithPath` | `errSecSuccess` (0) |
| `SecStaticCodeCheckValidityWithErrors`, flags `kSecCSCheckAllArchitectures \| kSecCSStrictValidate \| kSecCSCheckNestedCode` | `errSecSuccess` (0) |
| Same flags with the retained Developer ID requirement below | `errSecSuccess` (0) |
| Signing information, expected identifier/team and required entitlements | Match |
| `codesign --verify --strict --all-architectures --deep --verbose=4` | Valid on disk; designated requirement satisfied |
| `spctl --assess --type execute --verbose=4` | Accepted; Notarized Developer ID |
| `pkgutil --check-signature` against extracted installer | Trusted Developer ID Installer signature and certificate chain; expected team |
| `spctl --assess --type install --verbose=4` against extracted installer | Accepted; Notarized Developer ID |

The app has a stapled notarization ticket and an October 4, 2026 18:46:31 UTC signing timestamp. The installer has a trusted 18:46:32 UTC timestamp. The evaluated requirement was:

```text
identifier "com.trycua.lume" and anchor apple generic
and certificate 1[field.1.2.840.113635.100.6.2.6] exists
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
and certificate leaf[subject.OU] = "YCK386LBJ7"
```

These are static results for the recorded bytes and host tuple. They do not validate Guesthouse's production storage/verifier/launch integration or establish that any provider operation is safe and compatible.

## Remaining work

Migrate the retained verifier/probe to the current typed errors, storage ownership and XPC infrastructure before adopting a candidate pin. Preserve critical-file identity, nested-code checks and immediate pre-launch verification. Ordinary `runtimeVersion` remains an identity/status request; it must not silently execute provider diagnostics.

The release manifest classifies the spare-Mac Spaces-host fix ([upstream #4512](https://github.com/trycua/cua/pull/4512)) under `spaces-macos`, and the shared SSH event-loop fix ([upstream #3272](https://github.com/trycua/cua/pull/3272)) under `lume`. Upstream Spaces dogfooding does not prove Guesthouse's signed service, SSH registration, guest GUI or GPU behavior. The #4512 description also reports deleting failed creates in Cua Spaces; that behavior does not authorize Guesthouse to delete interrupted disks under [ADR 0004](../decisions/0004-disposable-environments-persistent-work.md).

The shipped macOS unattended presets still describe a default bootstrap account/password, autologin/SSH and disabled sleep/screen locking. Credential/access protection and the existing VNC/Stop/GPU proof requirements remain open. Actual provider inventory/adoption, persisted launch identity, whole-owned-set inspection after fork/restart and explicit metadata repair remain required by #24/#76/#32. An absent saved record or direct-child exit does not establish provider quiescence.

Production VM mutations remain disabled. A person must perform the reviewed bounded signed-app/provider preflight; a separate accepted provider-selection ADR and updated procedures must precede formal Lume hardware-gate records. No earlier failed Cloud head or unresolved acceptance requirement is waived by this artifact review.
