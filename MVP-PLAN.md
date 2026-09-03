# Guesthouse: GUI-first MVP technical plan

Build a native macOS app that prepares an isolated development Mac, connects it to the existing Codex desktop app, and manages multi-repository Xcode workspaces. The developer should not need Terminal, Homebrew, an SSH configuration tutorial, or a hand-written environment manifest.

The proposed implementation is a sandboxed SwiftUI app with a narrowly scoped, non-sandboxed XPC runtime service around the official Tart executable and OpenSSH. GitHub CLI and Codex CLI run inside the guest. Do not build a new chat interface, fork Tart or Codex, or implement a virtualization engine for the MVP.

Updated September 2, 2026. This is an implementation plan, not a description of a shipped product. Guesthouse is the chosen project name. Estimates are engineering estimates, not delivery commitments. The plan incorporates the external review of Xcode import, console/process ownership, guest updates, host sleep, and Codex version compatibility, plus the subsequent sandbox/XPC design discussion.

The first milestone is a thin GUI proof of the complete workflow, including the security and lifecycle boundaries. A phase-zero gate is a required experiment with a recorded result; it must not be treated as an already verified capability.

## 1. Define the smallest useful product

The MVP is complete when a developer can use the GUI to create a development environment, import Xcode, sign in to GitHub and Codex, select an app repository plus sibling Swift packages, and open that workspace in Codex. Codex must then edit both repositories, build and test inside the VM, and produce a draft PR in each changed repository. A cold reboot must not require repeating setup.

Use the existing Codex desktop experience for conversations, code review, and agent approvals. Guesthouse owns the environment and workspace setup. This division keeps the product useful without recreating an editor. This document calls the host application “Codex desktop”; follow the installed application's supported connection UI, which current OpenAI documentation describes within the ChatGPT desktop app.

### Initial scope

| Area | MVP decision |
| --- | --- |
| User interface | Native SwiftUI app with a setup wizard, environment dashboard, workspace detail, and repair sheets |
| Host | Apple silicon Mac; initial validation target is a 32 GB Mac mini |
| Placement | Codex desktop and Guesthouse on the same physical Mac initially |
| Host process boundary | Sandboxed GUI plus an embedded, non-sandboxed, ordinary-user XPC runtime service; prove the signed arrangement in phase zero |
| Virtualization | Official Tart application launched by the runtime service; private app-managed VM store |
| Lifecycle | Closing the main window keeps Guesthouse running; normal Quit stops VMs before exit; survival after app exit/crash is not promised |
| Console | Tart's native window for first boot/recovery; validate headless operation with reconnectable guest Screen Sharing for daily use |
| macOS images | Create locally from an Apple restore image; do not distribute an image containing accounts or Xcode |
| VM limit | At most two app-managed installed VM bundles, including stopped or recovery-preserved VMs; first working slice uses one |
| Workspaces | Many repository groups inside a persistent VM; a workspace is not another macOS installation |
| Repository storage | Independent Git clones on the guest's disk; no writable host repository sharing |
| Development | Ordinary Git-based Swift packages and a committed Xcode project with a shared scheme; native macOS MLX/GPU validation required |
| Accounts | GitHub.com and ChatGPT/Codex browser sign-in through the official guest CLIs |
| Publishing | Explicit push and draft-PR workflow, with one PR per changed repository |
| Updates | Tested runtime set, checks at every connection, user-approved guest maintenance; no unconditional boot-time upgrades |
| Distribution | Signed and notarized downloadable macOS app; not the Mac App Store |

The same-Mac starting point and stop-on-Quit behavior are proposed MVP scope choices, not requirements of virtualization. Confirm them before phase-one implementation. A laptop controlling a separate Mac mini, or VMs that must survive Guesthouse exiting, needs an additional host-supervisor milestone described in section 12. Neither changes the workspace model.

The VM cap is a conservative product constraint, not a complete interpretation of Apple's software license. Check the applicable macOS agreement before release, including other virtualization software installed on the host. Avoid a hidden third “golden image,” clone, or bootable recovery copy. Guesthouse can enforce its own inventory limit, not certify the host's total license compliance. [Apple software license agreements](https://www.apple.com/legal/sla/).

### Explicit exclusions

- Claude support, App Store Connect, distribution signing for developers' guest apps, and physical-device deployment. Signing and notarizing Guesthouse itself remain required.
- A custom Codex chat client or direct app-server protocol integration.
- A direct Virtualization.framework backend, VM fleet management, OCI image registry, or cloud scheduler.
- Writable host mounts, SSHFS, host SSH-agent forwarding, or access to the host's existing provider credentials.
- Automatic cross-repository merging, force-push workflows, or changes to existing branch protection.
- Arbitrary Xcode project layouts, package registries, generated-project tools, CocoaPods, submodules, and Git LFS until explicitly tested and supported.
- Snapshot trees, shared VM templates, and automatic delete-and-recreate repair.
- Guaranteed continuous execution after Guesthouse quits, crashes, the user logs out, or the host restarts; a persistent supervisor is a separate design decision.

These exclusions do not mean “CLI product.” The app uses command-line programs internally; the supported user journey remains graphical throughout.

## 2. Make the user journey concrete

### First launch

1. **Check this Mac.** Show architecture, supported macOS version, free disk, available memory, and whether Codex desktop is installed. Explain what will be downloaded and where the VM will live.
2. **Create a development Mac.** Choose a name and a recommended resource preset. Download and verify the tested Tart runtime and macOS restore image. Display real phase progress rather than one indefinite spinner.
3. **Finish macOS setup.** Open the Tart guest console. Guide the user through the supported local-account and Remote Login setup. Skip Apple Account sign-in. This is a one-time graphical step, not a Terminal instruction.
4. **Connect securely.** Establish and pin the guest's SSH identity, install dedicated access keys, and separate the normal development account from maintenance access.
5. **Add Xcode.** Use a native file picker to choose an existing compatible Xcode.app. If absent, open Apple's download page in the host browser and accept an official Xcode archive. Show the license-consent and component-installation stages explicitly.
6. **Sign in.** Present GitHub and Codex sign-in sheets with the provider URL, a copyable device code where applicable, and an “Open browser” button. Explain where credentials live and what the agent can do with them.
7. **Add a workspace.** Search accessible repositories, choose the app plus packages, and select a shared scheme and test destination. Show unsupported configurations before starting a large clone or build.
8. **Validate and open Codex.** Run a small environment check, then guide the user through Codex's supported SSH connection UI and folder selection. Copy the exact host alias and workspace path when needed.

The first-use wizard may open a guest console and provider browser. “No Terminal required” is achievable; “zero clicks in another window” is not the initial promise.

Stable macOS installation still involves guest setup in Tart's documented workflow. New macOS 27 provisioning APIs are worth revisiting, but a beta-only host/guest requirement should not define the MVP. [Tart quick start](https://github.com/openai/tart/blob/main/docs/quick-start.md), [Apple guest provisioning API](https://developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions).

### Returning developer

The main window shows environment cards with running state, readiness, disk usage, tool versions, and account status. Selecting an environment shows its workspaces and their repositories, branches, build results, and PR links.

Primary actions are **Start**, **Open in Codex**, **Open Mac console**, **Test workspace**, and **Publish draft PRs**. Put **Repair**, **Export work**, and **Delete environment** in a secondary menu. Do not make deletion look like a routine fix.

Closing the main window leaves Guesthouse and its runtime connection active in the menu bar. Normal Quit offers **Stop environments and quit** or **Cancel**; do not offer a keep-running option before a persistent supervisor is proven. Wait for the guest and Tart to stop before exiting. If graceful stop fails, offer cancellation or an explicitly warned force-stop. Warn that external Codex tasks may be interrupted: Guesthouse cannot reliably enumerate them through an undocumented desktop interface.

After a crash, sleep, or unexpected disconnection, show **Checking environment** rather than a cached Ready state. Reconcile the runtime, VM lock, guest identity, authentication, and tool compatibility before offering new operations. Do not create a replacement VM or restart a publication automatically.

### Essential screens

- Setup wizard with resumable stages and actionable failures.
- Environment dashboard with one or two slots.
- Workspace detail with repository status and separate local-integration and remote-CI results.
- Account sheets for sign-in, expiration, wrong-account recovery, and sign-out.
- Diagnostics and repair sheet with sanitized logs and export controls.

Use native controls, keyboard navigation, VoiceOver labels, selectable paths, and clear cancel/retry behavior. A read-only log disclosure is useful; an embedded terminal is not necessary.

## 3. Keep the architecture small

The relationship between the components is:

```text
Host Mac
├── Guesthouse.app — sandboxed SwiftUI GUI
│   └── Typed XPC connection
│       └── GuesthouseRuntime.xpc — launched by the system, ordinary user
│           ├── Tart.app — official runtime; launches the macOS guest
│           └── OpenSSH — approved provisioning/build/publish operations
└── Codex desktop — conversations, diffs, agent approvals
    └── OpenSSH — starts the guest Codex app-server

macOS guest
├── Xcode + selected Simulator runtime
├── Codex CLI / app-server + GitHub CLI + Git
├── Dedicated non-admin development account
└── Workspaces — app and package clones on guest-native storage
```

Codex already documents SSH-host connections and starts its remote app-server through the guest login shell. The guest needs a working Codex installation and authentication. Guesthouse does not need to host an app-server network listener or implement the chat protocol. The XPC connection manages host-side VM operations; SSH connects Codex to the guest. These are separate channels. [Codex remote connections](https://learn.chatgpt.com/docs/remote-connections).

### Xcode project and dependency setup

Create `Guesthouse.xcodeproj` using the macOS App template with SwiftUI and Swift. Start with Swift 6 language mode and the stable host deployment target selected during phase zero. Use an organization-owned bundle identifier and development signing team. Do not choose SwiftData or CloudKit for the initial template.

- `Guesthouse`: GUI target; keep App Sandbox and Hardened Runtime enabled, and enable only additional capabilities needed by implemented UI features.
- `GuesthouseRuntime`: embedded macOS XPC Service target; intentionally non-sandboxed for the direct-distribution prototype, with Hardened Runtime enabled. It is not a root daemon or login item.
- `GuesthouseCore`: one local Swift package for shared models, typed contracts, state transitions, and testable logic. Keep process-launch implementations in the runtime target rather than exposing a generic execution API to the UI.
- Unit tests for the core and runtime adapters, plus a small UI-test target for setup and recovery flows. Add the small bundled askpass helper when implementing SSH pairing.

Start with no third-party Swift package dependencies. Foundation, Security, OSLog, and the system OpenSSH tools cover the first slice. Tart is an external executable, not an importable package; Codex and `gh` are guest tools, not host libraries. Do not add a database, terminal emulator, SSH SDK, GitHub SDK, or updater framework before a concrete need exists.

The process directly using Virtualization.framework needs the virtualization entitlement. In the wrapper design that process is Tart, not the GUI. Keep the official runtime's signing intact; a source fork needs its own signing and any restricted-entitlement authorization. [Apple virtualization entitlement](https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project), [Tart package definition](https://github.com/openai/tart/blob/main/Package.swift).

### Sandbox and XPC boundary

An ordinary child launched by a sandboxed app inherits sandbox restrictions; using `Process` alone does not give Tart an independent security policy. An embedded XPC service can have a separate policy, including no App Sandbox in a directly distributed app. This is why the first prototype keeps the GUI sandboxed and moves the required host operations into a small service. [Apple sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html), [Apple's guidance for directly distributed apps](https://developer.apple.com/forums/thread/776609).

This design does not make the entire product sandboxed. The runtime service and Tart retain ordinary-user host authority and remain part of the trusted code base. Hardened Runtime, App Sandbox, guest isolation, and root privileges are different controls. Do not claim that one substitutes for another.

Expose named operations such as `startEnvironment`, `stopEnvironment`, `environmentStatus`, and `importXcode`, with environment IDs and validated configuration. Authenticate callers, validate message sizes and paths, reject symlink escapes, and choose executable paths and argument lists inside the service. Do not expose arbitrary shell commands, arbitrary executables, or unrestricted Tart flags. Guest output must never become a host instruction.

Pass user-selected import/export access explicitly using supported file-access handoff. A path string alone is not a transferable sandbox permission. Prove GUI-selected Xcode access, runtime storage access, and SSH/Keychain behavior in a signed build outside the debugger. [Apple file access between processes](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

The service also needs the correct logged-in user session for Keychain access and launching Tart's first-boot window. Evaluate `XPCService.JoinExistingSession` and verify the actual UI/keychain behavior; this setting is not proof that every Tart operation will work. Tart continues to own its own console process. [Apple XPC service configuration](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html).

Bundled XPC services are tied to their client's lifetime, so XPC alone is not a persistent VM supervisor. In addition, macOS 14.2 and later require an agent or daemon registered with `SMAppService` to be sandboxed when its containing app is sandboxed. Do not casually replace the service with an unsandboxed LaunchAgent registered by the same GUI. Revisit the installation and ownership design if survival after app exit is required. [Apple XPC service types](https://developer.apple.com/documentation/xpc), [Apple Service Management guidance](https://developer.apple.com/forums/thread/802443).

Keep documented XPC activity/transactions outstanding while supervising running VMs or operations. Returning a “started” reply and becoming idle must not allow normal service idle termination to abandon supervision. This does not override client-exit semantics. On connection interruption, treat an operation as having an unknown outcome until reconciled; do not replay it blindly. [Apple XPC transaction lifecycle](https://developer.apple.com/documentation/xpc/xpc_transaction_begin%28%29).

### Application components

Keep SwiftUI view state on the main actor and long-running host operations in the runtime service. The runtime owns the operation journal and environment mutations; the GUI observes status and requests operations. Avoid two independent writers to the same environment state.

| Component | Responsibility |
| --- | --- |
| `EnvironmentCoordinator` | State machine, operation ordering, cancellation, restart recovery, VM-slot accounting |
| `RuntimeClient` / XPC contract | Authenticated, versioned messages, status streaming, reconnection, validation |
| `TartBackend` | Runtime verification, create/start/stop, VM inventory, IP discovery, console lifecycle |
| `ProcessRunner` | Argument-safe process execution, output streaming, timeouts, termination, redaction |
| `SSHService` | Dedicated identities, trust records, managed aliases, connections, file transfer |
| `GuestProvisioner` | Versioned, repeatable guest setup and compatibility checks |
| `CompatibilityService` | Connect-time version/capability checks and explicit verified, unverified, or incompatible states |
| `MaintenanceService` | User-approved guest updates, restart coordination, and post-update validation |
| `HostPowerCoordinator` | User-visible idle-sleep policy, power changes, and sleep/wake reconciliation |
| `AccountService` | CLI sign-in adapters, status checks, secure-storage validation, sign-out |
| `WorkspaceService` | Repository selection, clones, manifest, local package integration, branches |
| `BuildService` | Scheme/destination discovery, test invocation, result summaries and artifacts |
| `PublicationService` | Publish preview, push, draft PR creation, partial-failure resume |
| `StateStore` | Versioned Codable records, atomic writes, operation journal |

A small backend protocol is useful for testing and a possible future direct-Apple implementation. Do not build a general plugin system before a second backend exists.

Use JSON metadata and an appendable operation journal initially. A database is unnecessary for two environments and a modest number of workspaces. Persist operation identifiers and completed checkpoints before updating the UI. On relaunch, reconcile actual VM, guest, and Git state; a saved “ready” flag is not proof.

### Local storage

Keep runtime downloads, VM data, maintenance SSH files, operation state, and diagnostics under a dedicated runtime-managed Application Support/Guesthouse directory, with separate subdirectories and restrictive permissions. The sandboxed GUI accesses runtime metadata through XPC and retains its own preferences in its app container; do not assume both processes resolve Application Support to the same place. Set `TART_HOME` to the runtime's approved VM store so lifecycle actions cannot accidentally target unrelated Tart machines. [Tart configuration implementation](https://github.com/openai/tart/blob/main/Sources/tart/Config.swift).

Export only the development SSH connection material needed by external Codex/OpenSSH to a dedicated user-approved location such as `~/.ssh/guesthouse/`. Do not assume Codex can read a private file inside Guesthouse's protected app container. Keep maintenance connection material out of that export and out of discoverable SSH aliases. Validate external access in phase zero before freezing the layout.

Store no provider token in the application metadata. Exclude private keys, tokens, device codes, authorization headers, and raw authentication logs from diagnostic exports. Prefer relative guest workspace paths and environment UUIDs over IP addresses as persistent identity.

### Process and trust boundaries

- Launch local programs using executable URLs and argument arrays, not interpolated host shell commands.
- Execute bundled, versioned guest operations with validated structured input. Treat filenames, branch names, remote output, and repository content as untrusted.
- Do not execute a host command suggested by a guest, repository, or coding agent.
- Pin command versions and test output adapters. CLI progress and authentication text are not stable JSON APIs.
- Use structured output for inventory, schemes, destinations, Git status, and PR information where supported.
- No host root daemon or general-purpose “run anything on my Mac” RPC in the MVP.

## 4. Provision a real development Mac

### Runtime delivery and console

Use the complete official Tart.app bundle, retaining its signature, entitlements, and provisioning profile. Do not extract and redistribute only the executable. Download a tested release through the GUI, verify its expected digest and signing identity, and preserve normal Gatekeeper handling. Offer a file-picker path to an existing compatible Tart.app when needed. [Tart repository and distribution notes](https://github.com/openai/tart).

Tart is an executable rather than an embeddable Swift library. Its own VM window is acceptable for initial setup and recovery; do not promise an embedded guest desktop inside our SwiftUI window. Extracting its engine into a library or passing a `VZVirtualMachine` through ordinary XPC is not the MVP approach. [Tart package definition](https://github.com/openai/tart/blob/main/Package.swift), [Tart run implementation](https://github.com/openai/tart/blob/main/Sources/tart/Commands/Run.swift).

### Console and process ownership

Treat **GUI session, VM ownership, and console lifecycle** as a named phase-zero gate, not a later UI detail. Current Tart supports headless execution with `--no-graphics`, but closing its normal native window can stop or suspend the VM. A native Tart window is not a detachable viewer. [Tart lifecycle implementation](https://github.com/openai/tart/blob/main/Sources/tart/Commands/Run.swift).

The proposed daily-use path is:

1. Launch Tart's native console for installation and Setup Assistant from the signed Guesthouse/XPC arrangement. Confirm the window is usable in the logged-in user's session.
2. During provisioning, explicitly configure guest Screen Sharing for designated guest users only.
3. Shut down and restart the same environment headlessly. Do not run two Tart instances against one disk.
4. Make **Open Mac console** open Apple's Screen Sharing client through an authenticated SSH tunnel bound only to host loopback. Protect guest access with its own authentication; store no password in a logged URL. Closing the viewer must leave the VM and builds running.
5. If guest networking or Screen Sharing fails, offer a controlled stop/restart into the native console, warning that it interrupts work. It is recovery, not seamless live attachment.

Tart's `--vnc` path relies on guest Screen Sharing; it does not enable that service and cannot replace first-boot console access. Do not use `--vnc-experimental`, which relies on private virtualization APIs, as MVP infrastructure. If native first-boot UI launch from XPC fails, the GUI-only setup gate remains blocked until a supported user-session launch arrangement is proven. [Tart Screen Sharing path](https://github.com/openai/tart/blob/main/Sources/tart/VNC/ScreenSharingVNC.swift), [experimental VNC implementation](https://github.com/openai/tart/blob/main/Sources/tart/VNC/FullFledgedVNC.swift), [Apple Screen Sharing settings](https://support.apple.com/guide/mac-help/turn-screen-sharing-on-or-off-mh11848/mac).

For the first slice, window close keeps Guesthouse running, normal Quit stops environments, and crash survival is not guaranteed. Persist process identity evidence and environment ownership, not only PIDs. After a GUI or broker crash, identify any surviving Tart process and its exact VM before recovering control. If ownership is uncertain, preserve the disk and request recovery; never launch a duplicate instance or kill an unrelated reused PID. Test termination, output-pipe handling, and shutdown deadlines explicitly.

Before public runtime redistribution or automated acquisition, confirm the applicable Tart license and the intended integration with its maintainers. The current repository uses FSL-1.1-ALv2, with a competing-use restriction; making our app open source does not alone resolve that question. This is a release check, not a reason to block a local technical prototype. [Current Tart license](https://github.com/openai/tart/blob/main/LICENSE).

### Version and resource policy

Start with one tested stable host/guest/Xcode combination. A reasonable current baseline is macOS Tahoe 26 on the host and a Tahoe guest compatible with Xcode 26.6; Apple lists macOS 26.2–26.x for that Xcode release. Freeze exact supported builds after the first hardware experiment, and revalidate before release. [Xcode system requirements](https://developer.apple.com/xcode/system-requirements).

For the 32 GB reference Mac:

- Start the first VM at 14–16 GB RAM, leaving headroom for host macOS and Codex.
- Make 12 GB per VM a dual-VM experiment, not a guarantee for every Xcode or MLX project.
- Initially run one VM at a time. Enable concurrent operation of the second slot only after memory-pressure and build tests pass.
- Start with a provisional 160 GB logical guest disk and roughly 200 GB host free-space planning allowance for the first setup, including temporary downloads and extraction. Replace these estimates with measured peak requirements before shipping.
- Distinguish sparse disk capacity from actual disk consumption. Check free space before each large operation, not only at first launch.

Do not preallocate half the available RAM to each VM unconditionally. Simulator processes, linkers, package builds, and model allocations create peaks; there is no universal “12 GB is enough for Xcode” threshold.

### Bootstrap and account separation

Use the guest console to finish stable macOS Setup Assistant and enable Remote Login. The wizard then establishes SSH using a local guest account, provisions a dedicated development identity, and hardens normal access.

Use an explicit, bounded trust-on-first-use pairing flow for the same-Mac MVP:

1. Record the UUID and MAC of the VM the app just created, and discover its NAT address through Tart. Do not accept an arbitrary remote address for this flow.
2. Explain that initial pairing trusts this Mac's virtual network. Require a trusted host and no hostile peer VM during pairing; MAC/IP correlation is not cryptographic identity proof.
3. Make the first SSH handshake with user authentication disabled, an isolated configuration, and an app-owned known-hosts file. Permit accepting a new server key only in this initial state; send no password or provider credential.
4. Persist the key against the environment UUID and use strict host-key checking for every subsequent connection. An unexpected replacement is a hard error, not an invitation to silently pair again.
5. Collect the guest-only bootstrap password through a native secure field. A bundled host-side `SSH_ASKPASS` helper supplies it through one-shot IPC and SSH's response pipe, never arguments, environment variables, or logs.
6. Install the authorized development and maintenance keys over the pinned connection. Prove key-based access before disabling password SSH and proceeding to provider login.

This is a concrete GUI-only design, but it cannot detect interception of the first handshake. Pinning before OAuth does not eliminate that first-use risk. Prove the exact OpenSSH behavior in phase zero and keep remote-host enrollment outside this trust model. [OpenSSH trust settings](https://man.openbsd.org/ssh_config#StrictHostKeyChecking), [OpenSSH askpass support](https://man.openbsd.org/ssh#SSH_ASKPASS_REQUIRE).

Keep bootstrap resumable. A partially paired machine must not be treated as a new unknown host on retry.

The final development account should be non-admin. Keep a separate maintenance identity controlled by the host application for Xcode installation and updates. Do not give the agent that identity, passwordless sudo, or host management access. Keep SIP and Gatekeeper enabled; do not copy permissive CI-image defaults into a personal-development product.

This separation is defense in depth. It does not turn a VM with network access and authenticated tools into a malware-proof environment.

### Xcode installation

Prefer importing a compatible Xcode.app selected by the developer. Copy only the selected bundle into guest staging, preserving its bundle structure, symlinks, and required metadata, then verify it before activation. Do not copy the host's Developer directory, Apple accounts, signing assets, or Keychain.

Benchmark two transports in phase zero before selecting the default:

- A streaming archive over authenticated SSH, extracted into guest staging.
- A temporary, narrowly scoped read-only Tart directory share of the selected Xcode bundle or dedicated import staging folder, copied into guest-local storage. Tart supports a `:ro` directory option. Do not share all of `/Applications`, the developer's home, or a repository tree. [Tart directory sharing implementation](https://github.com/openai/tart/blob/main/Sources/tart/Commands/Run.swift).

A read-only import share is compatible with the prohibition on writable host shares. It is not automatically faster: measure total import time, staging space, metadata preservation, interrupted-copy recovery, signature verification, and any restart needed to remove the share. Report macOS restore and Simulator download time separately so the transport comparison is meaningful.

Current Tart exposes shares as startup configuration; do not assume live share removal. The supported import path must shut down and relaunch the same VM without the share before enabling normal agent work. Unmounting the folder inside the guest is not host-side revocation. Verify the selected source did not change during import, reject inconsistent copies, and validate guest bundle integrity and signature before activation. Xcode must subsequently run from the guest's own disk.

Support an official Xcode archive as the alternative. Open Apple's download page on the host and let the developer authenticate there; Guesthouse does not own an Apple login flow in v1. Do not rely on the guest Mac App Store: Apple documents Apple Media Services restrictions in virtual machines. [Apple virtual-machine service limitations](https://support.apple.com/en-us/120468).

The wizard obtains explicit license consent, selects the installed developer directory, runs Xcode's first-launch setup inside the guest, and installs one chosen Simulator runtime. Copying Xcode.app is not proof that a Simulator runtime is installed. [Additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components).

The test gate is a real simulator build/test plus an unsigned or ad-hoc-signed macOS fixture, executed as the non-admin development user. List distribution signing, entitlement-dependent tests, and physical-device tests as unsupported rather than reporting them as passed.

### Guest security and software updates

Guesthouse owns update visibility, orchestration, and validation. The developer approves disruptive maintenance; the separate guest maintenance identity performs authorized administrative work. The non-admin agent account is not responsible for updating macOS or Xcode. Verify update authorization on the selected guest; administrator membership and volume ownership are distinct. [Apple software update process](https://support.apple.com/guide/deployment/dep02c211f3e/web).

Show installed versions, the last update check, available security updates, and whether a restart is required. Check when the environment reconnects and through **Check for updates**; unavailable update information must be shown as unknown rather than up to date. Do not silently turn off macOS security mechanisms to preserve a version pin. Explain any update preferences changed during provisioning and leave the user in control.

The GUI maintenance flow is:

1. Present the proposed OS, Xcode, or CLI change, its compatibility status, expected downtime, and recovery limits. Prioritize security fixes instead of deferring them indefinitely for an untested development-tool combination.
2. Ask the developer to finish external Codex work; drain Guesthouse-managed operations and record the current tool manifest and work inventory. Offer export before disruptive changes.
3. Apply the approved change using the maintenance account and supported guest mechanisms. Administrative SSH access alone does not guarantee unattended macOS update authorization. If the guest requires credentials, volume-owner authorization, or an interactive restart, guide the user through its console; never put passwords in command arguments or grant the agent passwordless sudo.
4. Reconnect using the pinned SSH identity and run Xcode, Simulator, secure-storage, private Git, and Codex readiness checks. Re-run the native MLX fixture after relevant OS/Xcode/graphics changes.
5. Record the result and retain actionable repair access if validation fails. Do not call an updated but untested environment Ready.

OS updates are not promised to be instantly reversible. Do not create an undisclosed bootable backup beyond the two-slot cap or describe a saved execution state as an OS rollback. Preserve the existing disk if recovery fails. Reverting a guest CLI may be possible after checking state-format compatibility; reverting macOS is a separate recovery operation.

Guest updates applied outside Guesthouse are detected as version drift on reconnect. Refresh compatibility and explain the change; never automatically downgrade the OS. Compatibility checks must not prevent access to the console, safe work export, shutdown, or security-maintenance repair.

### Host sleep and power behavior

Offer **Keep this Mac awake while environments run**, enabled by default on external power. Use a scoped macOS idle-system-sleep assertion while a VM or provisioning operation is active; allow display sleep and release the assertion when idle or the user turns it off. Do not permanently change the host's global power settings. External Codex jobs are not fully observable, so base the policy on running environments, not only Guesthouse's own build queue. [Apple idle-sleep activity option](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/idlesystemsleepdisabled).

On battery, warn that keeping a VM awake consumes power and ask for a separate opt-in; otherwise release idle-sleep prevention. Explain that manual Sleep, lid closure, shutdown, and power loss can still interrupt work. Do not promise to finish a VM save-state operation in a sleep notification or to run builds while the physical host sleeps.

On impending sleep, stop scheduling new app-managed work, flush the operation journal, and mark active operations as potentially interrupted. After wake, rediscover the guest IP, enforce the same host key, restore required tunnels, and recheck readiness and tool compatibility. Query actual build, transfer, Git, and PR state before retrying; interrupted publication is an unknown outcome, not proof the push or PR creation failed. Do not automatically restart a guest that the developer intentionally stopped.

## 5. Make SSH and provider sign-in dependable

### Host-to-guest SSH

Use one dedicated development identity per environment, separate from any existing GitHub SSH key. Store its encrypted private key with restrictive permissions in the approved development-SSH location that external Codex/OpenSSH can read, and its passphrase through macOS OpenSSH's Keychain integration. `UseKeychain` protects the passphrase; it does not mean OpenSSH reads a private-key blob directly from Guesthouse's Keychain. Test this from the actual desktop-started SSH process, not only the XPC service. [Apple OpenSSH Keychain guidance](https://developer.apple.com/library/archive/technotes/tn2449/_index.html).

Generate a concrete alias such as `guesthouse-dev-a1b2`. Configure an explicit identity, no agent forwarding, a Guesthouse-managed known-hosts file readable by external OpenSSH, strict host-key checking, and a stable host-key alias independent of the VM's current IP.

Ask permission once to add an app-managed block or Include to the user's SSH configuration. Back up the original, preserve unrelated entries, and validate effective settings with OpenSSH before claiming success. Remove only entries the app owns. Test discovery of the chosen layout in the real Codex desktop app; do not assume every Include arrangement is discovered.

Register only the non-admin development alias in that discoverable configuration. Keep maintenance identities in an app-private SSH configuration used only by internal maintenance operations, so Codex does not offer a privileged maintenance host alongside the development environment.

Codex exposes remote connection setup through its supported Connections UI. Guesthouse can open Codex and provide the alias and folder, but should not depend on an undocumented deep link, private database, or configuration mutation to register projects. [Codex remote connections](https://learn.chatgpt.com/docs/remote-connections).

### Codex sign-in

Wrap guest `codex login --device-auth` in a native sign-in sheet and verify completion using `codex login status`. Device authentication is beta and may require account or workspace permission. Provide the documented browser-callback fallback through a host-loopback SSH tunnel to guest port 1455; handle a busy port without terminating another application. [Codex authentication](https://learn.chatgpt.com/docs/auth).

Configure guest Keychain-backed storage with `cli_auth_credentials_store = "keyring"` before starting login. Do not silently import host authentication files or fall back to plaintext. If an unlock helper is required, it must receive secrets through a protected channel and use security APIs rather than embedding a password in command arguments.

Codex desktop starts its own remote server. Install a compatible guest CLI in the login-shell PATH, validate the connection, and leave server lifecycle to Codex. No custom server daemon, exposed TCP listener, or Codex fork is needed.

### Connect-time compatibility, not only update-time checks

The host desktop app can update independently of the guest CLI. A pinned guest executable is not a permanent compatibility guarantee, and desktop and CLI version numbers need not match numerically.

On every **Open in Codex**, guest reconnect, host wake, and detected desktop replacement:

1. Identify the selected desktop application and read its public bundle version/build metadata. If it cannot be identified, report the version as unknown rather than guessing or reading a private database.
2. Query the guest CLI version and executable path through the same login-shell environment used for remote sessions. Verify SSH identity, authentication readiness, and required tool availability. Detect multiple competing CLI installations.
3. Compare the observed host/desktop/guest/CLI combination with a versioned tested-compatibility manifest. Record tool capabilities and the last successful connection, not only version strings.
4. For a known-compatible, unchanged tuple, allow handoff after preflight. For an unknown tuple, show **Connection needs validation** and guide the user through a real desktop SSH connection. For known-incompatible versions, block new Guesthouse handoffs and offer an idle-time repair path. Preserve console access, shutdown, and work export in every state.
5. Record connection verification for that exact tuple only after the real desktop flow succeeds. If no supported machine-readable connection status exists, make the confirmation explicit in the GUI; do not claim an automatic handshake check or equate `codex --version` with a successful desktop connection.

A future CLI update is offered while idle, with a tested installation path and a retained previous executable where practical. Re-run authentication, Keychain, login-shell PATH, and actual desktop connection checks after replacing it. A binary rollback is not necessarily a state-format rollback. Do not update during active agent work, force-update the host desktop, or disable its normal updater.

Guesthouse can guard its own handoff workflow, not intercept every connection initiated directly in Codex. Label that limit in diagnostics. Native remote startup remains owned by the desktop app; this design does not create a second app-server protocol client. [Documented Codex SSH setup](https://learn.chatgpt.com/docs/remote-connections#connect-to-an-ssh-host).

### GitHub sign-in

Wrap the official web flow without a PTY, using the tested GitHub CLI's device-code output. The internal operations are:

```sh
gh auth login --hostname github.com --web --git-protocol https --skip-ssh-key
gh auth setup-git --hostname github.com
```

These are implementation details, not instructions the user must type. Verify the signed-in identity, credential storage, and private Git access before advancing. GitHub CLI documents a plaintext fallback if secure storage fails. If this occurs, remove the affected fallback credential through a tested, account-specific cleanup path, repair secure storage, and reauthenticate. Verify that no active plaintext credential entry remains before marking the account ready; reporting an error alone leaves the token behind. [GitHub CLI login](https://cli.github.com/manual/gh_auth_login), [Git credential setup](https://cli.github.com/manual/gh_auth_setup-git).

Validate provider URLs before opening them on the host. Handle cancellation, expired codes, denied organizational access, and wrong-account login. Do not retain device codes or raw authentication output in support bundles.

Display this warning before authorizing GitHub:

> The coding agent can use the GitHub permissions granted inside this environment. Selecting repositories here controls what we clone; it does not limit the account's token to those repositories.

For the fastest alpha, use provider-managed browser authentication and preferably low-risk test repositories. Repository-scoped credential brokering is a subsequent security milestone, not something the repository picker already implements. A GUI Publish button is also a workflow convenience, not a security boundary: an authenticated guest agent can use `gh` directly.

### Cold-boot readiness is mandatory

Public-key SSH does not automatically establish an unlocked interactive login session. Test whether both CLIs can use the guest Keychain after a cold boot, from independent SSH sessions and the desktop-started app-server.

Prefer a small, explicit unlock mechanism if required. If the supported image instead requires the developer to unlock the guest session in its console, expose an **Unlock development session** state and count those clicks in usability tests. Do not promise unattended operation until it is demonstrated. A credential-file fallback would be a separate, visible security decision, not an invisible implementation shortcut.

“Ready” means SSH, Xcode, account access, private Git access, and Codex connection checks pass. A successful ping or `uname` is insufficient.

## 6. Treat multiple repositories as a first-class workspace

### Workspace ownership and layout

Guesthouse owns a workspace manifest containing the environment ID, selected repositories, canonical remotes, local paths, base branches and SHAs, task branches, Xcode project, shared scheme, test destination, and draft PR identifiers. The GUI edits the manifest; the user never needs to write JSON.

Use independent clones per workspace initially. This costs some disk but avoids linked-worktree bookkeeping, shared `.git` paths, and cross-task branch conflicts in the first release.

Illustrative guest layout:

```text
Workspaces/feature-123/
├── AGENTS.md
├── workspace.json
├── Integration.xcworkspace/
├── repos/
│   ├── MyApp/.git/
│   ├── SharedUI/.git/
│   └── ModelKit/.git/
└── artifacts/
```

Select the common `feature-123` directory as the remote Codex project. Codex can then see all repositories and their Git metadata from one working directory. There is no requirement to combine them into one Git repository.

Prove the graphical review experience as well as shell access. A common parent is not itself a Git repository, and aggregate change review in Codex must not be assumed. If the tested desktop version requires selecting repositories separately, provide a guided per-repository review path. If that is too cumbersome or unavailable, add a small read-only, per-repository patch preview to Guesthouse before publishing. A list of commit SHAs is not a code review.

Generate workspace-specific agent guidance describing repository responsibilities, build commands, local package mapping, branch policy, and PR expectations. Guidance helps the agent; it is not access control. Keep generated integration files outside the individual repositories.

### Deterministic local package overrides

Do not rely on the agent to remember how to rewrite and later restore production dependency settings. Generate a wrapper `.xcworkspace` containing the app's `.xcodeproj` and selected local package directories. Build through that workspace so the local dependencies participate in resolution. Apple documents local package replacement, but the exact supported project shapes must be validated with fixtures. [Local package development in Xcode](https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package).

Before presenting a workspace as supported:

1. Resolve each selected package's identity and remote association; do not match only the display name in `Package.swift`. For ordinary Git URL dependencies, preserve the expected repository-derived checkout basename and validate its canonical `origin`.
2. Reject ambiguous identities and unsupported dependency layouts with a useful explanation.
3. Generate the wrapper without editing the committed app project or package manifests. Seed its own resolution file from the canonical lockfile where applicable, then resolve inside the wrapper and keep its generated state outside the repositories.
4. Test direct and transitive local dependency cases.
5. Confirm that production project files and their committed resolution files remain unchanged after the integration build.

Git URL package identity is derived from package location rather than necessarily matching `Package(name:)`; preserve canonical URL information and test collisions. [SwiftPM package identity implementation](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageModel/PackageIdentity.swift).

For the first release, support a committed `.xcodeproj` and shared scheme. Detect complex existing workspace composition instead of silently rewriting it. Extend support when a test fixture establishes the correct behavior.

Use `xcodebuild -workspace` for the generated integration workspace; a build against only the original project does not prove the local override is active. Keep DerivedData and package caches in workspace-owned guest locations. Do not confuse cache-location flags or repository mirrors with editable local-package overrides.

### Build results must have two meanings

- **Local integration test:** the app builds against the sibling package changes in this guest workspace.
- **Canonical repository test:** the committed app builds using its normal remote dependencies in CI.

A green local integration test does not prove the consumer PR will pass after publication. Keep both statuses visible. When a package API changes, the package may need to merge and receive a release or commit pin before the app's dependency update becomes valid.

Preserve the existing Codex push reviews and Xcode Cloud checks. Do not alter required status checks or merge gates to make a multi-repository change appear complete.

### Concurrency

Support one active change-set per workspace. The app serializes its own Git/build operations and warns against simultaneous Codex tasks editing the same workspace. Since Codex is an external application, treat this as a workflow constraint rather than a lock the app can enforce against every agent action. Separate workspace directories reduce Git conflicts, but are not a security boundary between agents sharing one guest account; such an agent can still affect other workspaces visible to that account.

## 7. Publish cross-repository work without pretending it is atomic

The app creates a task branch in each selected repository, records its base SHA, and uses explicit repository paths and remote identities for every operation. Use the equivalent of `git -C` and an explicit `gh --repo` context rather than relying on whichever working directory a previous command happened to use.

Codex writes and tests code and can prepare commits. The GUI's Publish flow expects reviewed, committed changes. It must not silently stage every untracked file or invent commits containing secrets or build artifacts.

### Publish flow

1. Ask the developer to finish active agent edits and review the change-set.
2. Show changed repositories, destination owners, branch names, commit SHAs, and available test results.
3. Reject unexpected remotes, detached or incorrect branches, missing commits, and dirty trees that make the preview stale.
4. Push each approved commit to its recorded task branch without force-pushing. Use an explicit repository context and capture the exact published SHA.
5. Find or create one draft PR per changed repository. Link related PRs and describe dependency ordering.
6. Record each completed push and PR immediately. On failure, display partial success and resume without duplicating PRs.

Check the repository state again before each publish operation. If Codex changed it after preview, stop and ask for a refreshed review. There is no all-or-nothing transaction across GitHub repositories.

The minimal GUI shows PR links and check summaries; it does not recreate GitHub's review interface. Never auto-merge. A package PR and its consuming app PR can legitimately have different readiness states.

## 8. Define what isolation does and does not protect

The design goal is to prevent ordinary agent file operations inside the guest from modifying the developer's host filesystem. Keep all writable source, package caches, DerivedData, and build output inside the guest. Do not mount the host home directory or repository tree.

Additional defaults:

- The GUI is sandboxed; the XPC runtime and Tart are not. Keep their host authority narrow through the validated operation interface, and do not label the entire host product sandboxed.
- A narrow read-only Xcode import share is the only planned host-share exception, removed by a confirmed VM restart before normal agent work.
- No host SSH-agent forwarding, copied host provider tokens, shared Keychain, or unrestricted clipboard synchronization.
- Normal agent sessions use the non-admin guest account.
- Guest maintenance keys remain host-controlled and are never exposed to Codex.
- No exposed app-server port and no general host command endpoint.
- Recommend FileVault on the host volume storing the VM and keys.
- A host-key change requires repair/re-pairing; never automatically accept it because the IP looks familiar.

Default NAT is connectivity, not complete network isolation. The guest may still reach host or LAN services and the internet. Provider credentials remain usable by the agent after sign-in. State both limitations in the UI; do not market the MVP as safe for arbitrary hostile code or unrestricted cloud-account operations.

Reduced agent prompts require an explicit guest-only permission choice in Codex. Keep its approval UI and account policies intact. Do not automatically change the host's global agent settings or promise that SSH removes approvals.

### Metal and MLX validation

Treat GPU support as a capability test of the selected guest, not “full GPU passthrough.” Apple's virtualization graphics stack and the particular Metal workload need validation on the reference Mac. [Apple's macOS virtualization graphics overview](https://developer.apple.com/videos/play/wwdc2022/10002/).

Native macOS MLX is a user requirement and a phase-zero gate. Run a small GPU operation in the guest, verify its execution path, compare correctness with the host, and measure memory pressure. If this fails, return to the user for a scope or architecture decision before treating the plan as viable. Do not silently substitute CPU execution, and do not infer training performance or support for a large model from a small successful test.

Keep native macOS MLX testing separate from iOS Simulator testing. MLX Swift documents that Simulator lacks the required Metal capability; a mocked or skipped inference test is not a passing on-device inference test. Physical-device validation remains outside this MVP. [MLX Swift iOS limitations](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Documentation.docc/Articles/running-on-ios.md).

## 9. Make repair preserve work

Treat provisioning as a state machine with checkpoints:

```text
Preflight → Runtime ready → macOS installed → Needs guest setup
→ SSH paired → Guest secured → Xcode/tools ready → Accounts ready
→ Workspace validated → Ready
```

Each stage can become canceled, recoverable failure, or needs user action. Retry inspects actual state before repeating a step. Keep interrupted downloads and installation staging distinct from verified usable artifacts.

Offer targeted repair for SSH/IP changes, locked credentials, expired login, missing runtime, tool mismatch, or incomplete Xcode components. Do not implement Repair as “delete the VM and start again.”

### Protect unpublished work

Before deleting a workspace or environment, inventory every registered repository for working changes, untracked and ignored files, local branches, and unpushed commits. Offer an export to a user-selected location. A Git bundle alone does not preserve all working-tree files.

Before export, ask the developer to stop active agent edits and quiesce app-managed jobs. Record source inventories and content hashes before and after export; fail and retry if the source changed. The app cannot enforce an external Codex task lock. Export complete selected workspace data with a manifest and integrity checks, explicitly identifying any excluded caches or artifacts. Test restoration, not merely archive creation. If unpacking guest data on the host, reject path traversal and unsafe symlink behavior and use an isolated destination.

A completed export is not permission to delete a later, changed source. Before committing environment deletion, stop the guest and establish a final stable-source barrier: verify that the exported work covers the final source state using a supported inspection mechanism. Before/after hashes from an earlier live export do not close the export-to-deletion race. If stable verification is unavailable, default to preserving the entire stopped original environment. An explicit discard path must warn that newer or unverified work may be lost; it must not display “all work backed up.” Do not add an untested offline disk mounter merely to claim this guarantee.

Managed-workspace inventory does not cover every file an agent might create elsewhere in the guest. The final deletion sheet must name that coverage limit and the directories being discarded. Offer **Preserve entire environment** instead of deletion: stop and retain the original VM bundle, optionally relocating it, without making another bootable copy. It continues to consume a slot. Deletion after a limited export requires an explicit acknowledgment that other guest data may be lost.

If the guest cannot boot or answer SSH, preserve its disk and describe recovery as incomplete. Do not delete an inaccessible disk on the assumption that all work was pushed. A preserved broken VM still consumes one of the two slots.

Gracefully shut down the guest before lifecycle operations when possible. Force-stop requires a separate warning. Saved VM execution state is not a substitute for a disk snapshot or a work backup.

Sign-out removes local credentials where supported and links to provider revocation controls. Do not claim that deleting the VM or running a CLI logout revokes every server-side token or session.

## 10. Deliver in six phases

Build an end-to-end proof first, then make that exact path repeatable. Avoid completing a polished dashboard before knowing that first boot, Keychain, Codex, and Xcode work together.

The estimates assume one experienced macOS engineer, one reference Mac, and a narrow tested compatibility set. Download time, provider approvals, and external review are additional variability. Some work can run in parallel after phase zero.

| Phase | Effort estimate | Visible deliverable | Exit gate |
| --- | --- | --- | --- |
| 0. Prove the complete path | 4–7 engineer-days | Signed GUI/XPC harness with real VM and two-repo fixture | Lifecycle, import, cold-boot auth, native MLX, and two-PR gates recorded |
| 1. Build the application shell | 4–6 days | Environment dashboard, runtime IPC, operation progress, durable state, start/stop/console | Window-close and Quit contracts hold; crash recovery never duplicates a VM |
| 2. Make setup repeatable | 6–10 days | First-run wizard, verified runtime, guest setup, Xcode import, maintenance, power handling | Fresh test user reaches Xcode validation without Terminal; sleep/update recovery works |
| 3. Integrate accounts and Codex | 3–5 days | Native provider sign-in, SSH alias management, Codex handoff | Cold boot, login expiry, and app restart all have working GUI recovery |
| 4. Finish multi-repo workflows | 4–7 days | Repo picker, local package workspace, graphical review, tests, draft-PR publishing | Real app/package change-set and partial-publish retry pass |
| 5. Harden and distribute | 7–11 days | Recovery export, signed packaging, security tests, accessibility, pilot fixes | External developers complete the workflow without developer assistance |

Revised planning range: 28–46 engineer-days, roughly 6–10 working weeks allowing for integration contingency. This replaces the earlier 22–36-day estimate: the sandbox/XPC boundary, reconnectable console, security maintenance, and negative lifecycle tests are real additional work. It includes the proposed Screen Sharing path, but not a persistent supervisor, native virtualization backend, or separate-Mac hosting. Re-estimate if a phase-zero gate requires one of those changes. An internal happy-path demo can arrive earlier; it is not a public beta.

### Phase 0: Prove the complete path

Create `Guesthouse.xcodeproj`, the sandboxed GUI target, the runtime XPC target, and the local core package. First prove one named **Runtime version** request against a verified Tart bundle. Then add buttons for each experimental step and sanitized status. Use the fake backend for previews; do not add account integrations before host execution works.

Implementation scripts and manual engineer diagnostics are acceptable during the experiment; record which actions must become GUI operations before beta. Test a signed app launched outside Xcode as well as a debug build. Complete these named gates:

| Gate | Required proof and decision |
| --- | --- |
| Host boundary and signing | Sandboxed GUI reaches only authenticated named XPC operations; ordinary-user runtime launches the official Tart bundle; caller rejection, file handoff, Keychain/session access, and VM-store isolation work |
| GUI session, VM ownership, and console lifecycle | First-boot native console works; provisioned headless VM survives viewer/main-window closure; normal Quit stops it; GUI/broker crash and relaunch cannot double-start a disk; first-boot recovery does not depend on preconfigured Screen Sharing |
| SSH pairing and cold-boot credentials | GUI-only pairing pins the guest before credentials; changed key is rejected; external Codex can read the development SSH material but receives no maintenance alias; both providers work through guest Keychain after a cold boot |
| Xcode import transport | Benchmark SSH archive versus narrow read-only share end to end, including metadata, signature, interruption, staging, and detach/restart; choose a default and retain the other only if worth supporting |
| Non-admin Xcode and native MLX | Real Simulator build/test and macOS fixture pass as the development user; native MLX runs on the guest GPU with correct results and recorded memory pressure |
| Multi-repo workflow and review | App/package edits participate in the wrapper build; committed project/lockfiles stay unchanged; every changed repo has usable graphical review; two disposable draft PRs retain the existing required checks |
| Maintenance and sleep recovery | User-approved guest update has a working authorization path; wake restores identity/readiness without replaying uncertain writes; no hidden bootable backup or irreversible automatic repair |
| Desktop/CLI compatibility | Current desktop performs a real SSH connection; changed/unknown/incompatible tuples produce the defined states; no automatic mid-session CLI replacement or invented compatibility API |

Repeat the complete path on a fresh environment, retiring or preserving the previous one within the two-slot cap. Record exact versions, pass/fail evidence, total setup time, active user time, peak disk and memory use, and guest-console interventions. Keep the result with the fixture in the repository.

If first-boot UI, runtime ownership, secure cold-boot auth, or GUI-only pairing fails, resolve it before expanding the UI. Do not silently disable the GUI sandbox, introduce a root daemon, or fall back to Terminal to declare the gate passed. If local overrides fail, narrow the supported project shape explicitly. If native GPU validation fails, obtain a scope or architecture decision; CPU success is not GPU success.

### Phase 1: Build the application shell

Implement the proven lifecycle boundary, typed XPC client/service, process execution, durable environment state, and a fake backend for previews/tests. Put operation ownership and VM-slot reservations in the service, with observable UI adapters. Add interfaces or stubs for later maintenance, account, workspace, build, and publication services rather than implementing all services at once. Start with one environment and one in-flight lifecycle operation.

Add progress, cancellation, retry, sanitized logs, and error categories such as unsupported host, insufficient disk, failed download verification, guest not reachable, and credentials locked. Never show “something went wrong” as the only recovery information.

Implement the phase-zero window-close, viewer-close, and stop-on-Quit contracts. Reconcile process identity safely after relaunch; do not trust a reused PID, assume every crash killed Tart, or assume any surviving process can be safely restarted. Treat an interrupted XPC request as an unknown outcome until inspected.

### Phase 2: Make setup repeatable

Implement the verified bootstrap rather than inventing a second path. Add compatible runtime selection, integrity checks, per-step storage preflight, temporary staging, the chosen Xcode import transport, and one Simulator runtime. If import uses a read-only share, make detach/restart verification part of the wizard's completion condition.

Keep a versioned compatibility manifest with the host OS, selected desktop application/build, runtime protocol, Tart, guest macOS, Xcode, Codex CLI, GitHub CLI, and provisioning script versions. Implement the maintenance identity's update workflow and the host sleep/power policy in section 4. OS drift triggers validation and an actionable state, not silent downgrade or indefinite security-update deferral.

Test interruption at every stage: canceled download, disk exhaustion, closed console, failed password, partial Xcode copy, update restart, battery transition, sleep, and host restart. Resuming should reuse verified completed work and preserve uncertain outcomes for reconciliation.

### Phase 3: Integrate accounts and Codex

Build provider adapters around the pinned CLIs. Add device-code UI, callback fallback, expiry/cancel/retry, guest Keychain checks, and account identity display.

Generate and verify the SSH alias without overwriting unrelated configuration or exposing maintenance access. Implement the connect-time compatibility states and guide the developer through the documented connection screen. Acceptance requires opening the actual guest workspace in Codex, not only a successful background SSH health check. Repeat after replacing the desktop app or guest CLI with a supported test version.

Test a new CLI release before offering an update. Install updates while idle and retain the last working executable where practical. Avoid unconditional boot-time upgrades that could break sign-in parsing or a desktop/server compatibility pair.

### Phase 4: Finish multi-repo workflows

Build the repository picker and manifest, direct clones, task branches, wrapper workspace, scheme/destination selection, local build results, and explicit publication flow.

Use the graphical per-repository review path validated in phase zero. Budget a minimal read-only patch preview if Codex cannot provide a usable review from the multi-repo setup; do not expand this into an editor or general Git client.

Use fixture projects for direct packages, transitive packages, identity collisions, wrong remotes, missing shared schemes, and unavailable simulator destinations. Cover partial clone and partial publish failure. UI status must identify the failing repository.

Prove the package-first publication sequence with the existing CI system. A cross-repo change is complete only when its canonical dependencies and required checks are correct, not merely because both draft PRs exist.

### Phase 5: Harden and distribute

Add work export and restore validation, destructive-action safeguards, locked/expired credential repair, and diagnostic export. Exercise a second environment slot without hidden base copies. Enable dual-VM execution only if the resource tests justify it.

Sign and notarize Guesthouse and its own helpers; validate the complete download on a clean Mac with Gatekeeper enabled. Preserve the official Tart runtime's separate signing/provisioning. This product-distribution signing is still required even though signing the developer's guest apps is deferred. Test guest Keychain access after CLI replacement, helper protocol version skew, app replacement with VMs running, and rejected XPC clients. Include applicable third-party notices and resolve the Tart distribution review.

Run a pilot with three to five developers who have not seen the implementation. Watch them onboard from the GUI without spoken instructions. Fix the points where they need Terminal, undocumented paths, or the engineer's intervention.

## 11. Test the promises, not only the services

Run unit and parser tests without booting VMs. Run real virtualization tests on a dedicated Apple silicon Mac; do not assume a generic hosted CI machine supports the required virtualization configuration. Use disposable repositories and test accounts for destructive and publication cases.

| Test group | Required cases |
| --- | --- |
| GUI setup | Fresh host user, no Homebrew, no Terminal commands, canceled steps, keyboard and VoiceOver navigation |
| Runtime integrity | Bad download digest/signature, partial archive, unsupported host, existing unrelated Tart installation |
| XPC boundary | Unauthorized caller, malformed/oversized request, path traversal/symlink escape, arbitrary-executable rejection, idle transaction lifetime, helper protocol mismatch, signed Finder-launched app |
| Lifecycle | Native first-boot console from broker, native-window closure, headless startup, Screen Sharing close/reopen, main-window close, Quit/cancel/force-stop, broker/GUI crash, surviving child and reused PID |
| Sleep and power | Idle-sleep assertion release, display sleep, battery transition, manual sleep/lid closure, wake with changed guest IP, expired session, interrupted transfer/build, uncertain push/PR outcome |
| SSH | Existing complex config, external desktop access to exported development keys, hidden maintenance aliases, wrong first-use target, changed host key, missing key, locked host Keychain, no agent forwarding |
| Provider auth | Disabled device flow, callback port occupied, expired code, canceled browser flow, wrong account, revoked access |
| Guest storage | Cold-boot Keychain use, separate SSH sessions, CLI replacement, plaintext fallback detected and removed, guest GUI session locked |
| Xcode transport | SSH/share end-to-end benchmark, narrow read-only access, unchanged host source, metadata/symlink preservation, source changes during copy, disk exhaustion, guest verification, restart with share absent |
| Xcode | Missing runtime, failed first launch, non-admin Simulator use, unsigned/ad-hoc macOS test, unsupported signing needs |
| Guest maintenance | Update availability unknown, user consent/cancel, missing authorization, reboot interruption, externally applied update, failed validation, preserved disk, security repair accessible despite compatibility failure |
| Codex compatibility | Desktop updated independently, guest CLI changed/multiple installations, known-incompatible and unknown tuples, failed real SSH connection, explicit verification state, no mid-session replacement |
| Repositories | Multiple owners, private access, partial clone, duplicate package identity, changed origin, untracked files |
| Local integration | Direct and transitive package edits, correct wrapper build, production project and lockfiles unchanged, graphical review of every changed repo |
| Publishing | Two changed repos, one unchanged repo, failed second push, retry without duplicate PRs, stale preview, no force push |
| Recovery | Unpushed commits, ignored files, archive integrity, failed restore, unreachable guest, preserved disk, external write after export but before deletion, stable-source verification unavailable |
| Isolation | No writable host shares, import share absent before agent access, no maintenance key in agent account, no guest access to XPC, no arbitrary host-command interface |
| Resources | Actual peak storage, 32 GB host memory pressure, optional two-VM contention, native Metal/MLX fixture |
| Distribution | Clean-machine Gatekeeper/notarization path, version compatibility, notices, safe app upgrade |

Public-beta release criteria:

- At least three fresh-user pilot runs reach a working Codex workspace without Terminal or hand-edited configuration.
- The complete app-plus-package fixture passes after a cold boot.
- The signed sandboxed-GUI/runtime arrangement passes first-boot console, caller validation, and external SSH/Keychain checks on a clean Mac.
- Closing the ordinary console viewer does not stop a build; Quit, crash, and recovery behave as documented and never double-start a VM disk.
- The selected Xcode transport has measured end-to-end costs and leaves no host share attached during normal agent work.
- Guest security updates have a visible owner and usable maintenance path; host sleep/wake never blindly replays uncertain mutations.
- An independently updated desktop or CLI cannot retain a stale verified-compatibility badge; unsupported connection checks are not represented as automatic proof.
- Every failed wizard stage has a specific recovery action.
- A failed second-repository publish does not lose the first PR or create duplicates.
- Deleting or repairing an environment cannot silently discard unpublished work.
- The UI accurately distinguishes host-file isolation, guest credential authority, local tests, and canonical CI.
- Setup duration, active user time, disk requirements, and memory guidance are based on measurements.

## 12. Sequence the follow-on work

### Persistent local supervisor

If VMs must survive Guesthouse quitting or crashing, make that a separate architectural milestone before promising it in the UI. Select a supported per-user ownership, installation, signing, approval, IPC, removal, and update arrangement. Address `SMAppService` sandbox requirements explicitly; an embedded unsandboxed XPC service cannot be mechanically relabeled as an unsandboxed LaunchAgent registered by the sandboxed GUI.

The supervisor must reconcile VM locks and operation outcomes after controller loss, reject unauthorized clients, and support graceful shutdown and removal without losing work. Avoid a host root daemon unless a specific, reviewed requirement proves it necessary. Keeping the GUI alive in the menu bar is not equivalent to implementing this milestone.

### Separate Mac mini hosting

After the same-Mac path works, add a controller on the developer's laptop and a narrowly scoped host component on the Mac mini. Reuse the same VM, workspace, and account model.

This requires graphical host pairing, authenticated lifecycle commands, host availability/status, routing to the guest through an SSH jump or tunnel, changing addresses, sleep policy, and two layers of host-key trust. The management channel must expose named operations, not arbitrary host shell execution. Keep the Codex data path over SSH.

Do not silently enable the Mac mini's Remote Login or expose guest SSH to the public internet. Give the user an explicit setup and network-access choice. Decide whether this should use a supported private-network product before implementing discovery and NAT traversal ourselves.

### Tighter GitHub permissions

Add an explicit repository-scoped credential approach when the product needs a stronger cloud-account boundary. Evaluate a fine-grained token flow for a narrow same-owner use case, or a GitHub App/broker for broader use. Neither should be presented as a free property of VM isolation.

### More environment capabilities

Expand tested Xcode/project layouts, template and backup handling within the VM limit, automatic first boot when stable Apple APIs permit it, and eventually Claude support. A fully sandboxed host runtime or deeply embedded console may justify a sandbox-aware Tart fork or direct Apple backend; neither is necessary merely to put the current executable behind XPC. Reassess against measured UX, maintenance, signing, and licensing costs.

## 13. Recommended first implementation task

Build the phase-zero Guesthouse SwiftUI/XPC harness and an app-plus-package fixture. Start with a named runtime-version request and a fake backend. Its full success condition is one recorded run from VM creation through a cold-boot Codex connection to two draft PRs, with Xcode tests and native MLX validation executing in the guest, plus the named lifecycle and recovery gates.

That experiment answers the costly questions before UI polish: the signed sandbox/XPC boundary, first-boot and returning console behavior, first-use SSH trust, cold-boot Keychain access, real desktop/CLI compatibility, local Swift package resolution, import performance, maintenance/sleep recovery, and the practical resource budget. Record decisions and measured versions, then turn the proven steps into the production wizard.

