# Lume 0.6.0 static artifact review

Recorded October 1, 2026 (UTC), after the official release at 17:19:11 UTC. This is static artifact evidence for [issue #82](https://github.com/PicoMLX/Guesthouse/issues/82), [ADR 0002](../decisions/0002-prioritize-lume-and-shared-infrastructure.md) and MVP-PLAN.md §3. It is not provider selection, a runtime installation, signed-XPC execution, VM/guest evidence or a phase-zero hardware result.

The new artifact passes the checks below on an arm64 Mac running macOS 26.6.2 (25G83). The earlier Lume 0.5.3 artifact remains rejected. No Lume executable, archive launcher or installer was run, and no existing runtime or VM disk was changed.

## Official source and measured identities

- [Release and checksums](https://github.com/trycua/cua/releases/tag/lume-v0.6.0).
- [Versioned arm64 app archive](https://github.com/trycua/cua/releases/download/lume-v0.6.0/lume-0.6.0-darwin-arm64.tar.gz).
- [Versioned installer archive](https://github.com/trycua/cua/releases/download/lume-v0.6.0/lume-0.6.0-darwin-arm64.pkg.tar.gz).
- [Release manifest](https://github.com/trycua/cua/releases/download/lume-v0.6.0/release-manifest.json): source revision `2b314a1c97c6017d0676c9ee64254e8dfddb477a`.

The downloaded bytes matched both the release API asset metadata and manifest. Extraction was confined to a private temporary directory after rejecting links, special files, absolute/traversing names and excess entry/expanded-byte counts. The app archive has 16 entries totaling 21,671,990 expanded bytes; the installer archive contains only the 6,133,812-byte `lume.pkg`.

| Item | Measured value |
| --- | --- |
| App archive bytes / SHA-256 | 6,114,070 / `4d25c7c36ebd3fdf0e2f97f9e7a2c4ff2d0538ba9eb2d536f6dbb542d9d504a7` |
| Installer archive bytes / SHA-256 | 6,055,649 / `c93322a9739cc085117fe4a9aa177d2e98a1c58c1ab84f7cceaf0bac8625fcc3` |
| Manifest bytes / SHA-256 | 4,756 / `a2737ec28cdb1fd20f7a56a440d8f79d97f87b276ab1ae3dc99faa46492d780a` |
| `Contents/MacOS/lume` SHA-256 | `4e3ef86853685b59d76ff08d1cfffc960ea62c0d9dfc868c23d032e06d515391` |
| CodeDirectory hash | `83d288bc8a54063bc892644767f402e9b82e8101` |
| Bundle and signing identifier | `com.trycua.lume` |
| Bundle version / executable | `0.6.0` / `lume` |
| Architecture / signing | arm64 / Hardened Runtime, Developer ID Application |
| Team identifier | `YCK386LBJ7` |
| Entitlements | `com.apple.security.virtualization=true`, `com.apple.vm.networking=true`; no additional entitlement keys |

## Static checks performed

The retained #83/#86 verifier requires strict, all-architecture and nested-code validation, plus the specific Developer ID identity. A trusted local Swift probe compiled with Swift 6 and warnings as errors invoked Security.framework against the downloaded app, without running the app:

| Check | Result |
| --- | --- |
| `SecStaticCodeCreateWithPath` | `errSecSuccess` (0) |
| `SecStaticCodeCheckValidityWithErrors`, flags `kSecCSCheckAllArchitectures \| kSecCSStrictValidate \| kSecCSCheckNestedCode` | `errSecSuccess` (0) |
| Same flags with the retained Developer ID requirement below | `errSecSuccess` (0) |
| Signing information, expected identifier/team and required entitlements | Match |
| `codesign --verify --strict --all-architectures --deep --verbose=4` | Valid on disk; designated requirement satisfied |
| `spctl --assess --type execute --verbose=4` | Accepted; Notarized Developer ID |
| `pkgutil --check-signature` against extracted installer | Developer ID Installer, expected team; trusted notarization |

The app has a stapled notarization ticket and an October 1, 2026 17:17:55 UTC signing timestamp. The installer has a trusted 17:17:56 UTC timestamp. The requirement evaluated was:

```text
identifier "com.trycua.lume" and anchor apple generic
and certificate 1[field.1.2.840.113635.100.6.2.6] exists
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
and certificate leaf[subject.OU] = "YCK386LBJ7"
```

These checks establish the static result for these exact bytes on this host. They do not prove Guesthouse's production verifier/storage/launch integration or that the provider's operations are safe and compatible.

## Remaining work

Review and migrate the retained verifier/probe on the current structured-error, storage and XPC infrastructure before adopting a new production pin. Do not merely replace the old version/digest constants or activate an old raw-log consumer. Preserve critical-file identity, nested-code and immediate pre-launch verification requirements.

The release notes advertise running without a VNC listener, changes to detached Stop/timeout behavior and macOS GPU passthrough. Those are upstream claims to inspect and test under the approved bounded diagnostic, not guest functionality or isolation evidence. The shipped unattended presets still advertise a default bootstrap account/password, autologin/SSH and disabled sleep/screen locking; credential and access protection remain required before an experiment.

Actual provider inventory/adoption, persisted launch identity and explicit metadata repair remain required by #24/#76/#32. A saved record's absence does not establish that a VM stopped. Production VM mutations remain disabled. A person must perform the reviewed signed-app/provider preflight, and a separate accepted provider-selection ADR and updated procedures must precede formal Lume hardware-gate records. This review closes none of those requirements.
