# Lume substrate preflight runbook

Run state: **not run**

Tracking issue: [#82](https://github.com/PicoMLX/Guesthouse/issues/82)

Candidate: official Lume `0.5.3` (`lume-v0.5.3`)

This is a provider preflight for #82, not one of the Phase-0 gate records registered in `docs/phase0/README.md`. [MVP-PLAN.md §1, “Initial scope”](../../MVP-PLAN.md#initial-scope) still selects the official Tart application, and [§10, “Phase 0: Prove the complete path”](../../MVP-PLAN.md#phase-0-prove-the-complete-path) governs which hardware experiments become gate records. Record this preflight's human observation on #82; do not create a `docs/phase0` record unless an accepted ADR selects Lume and a separate change updates the plan, gate issues, registry, and template. Source review, CLI help, and unit tests do not pass a named Phase-0 gate.

## What the automated spike implements

The runtime service locates only `~/Library/Application Support/Guesthouse/runtime/lume-v0.5.3/lume.app`, rejects symlinked managed paths, and implements these static checks before execution:

- canonical CDHash: `320e86c91aefaf7e283bde6560a699c44e931c2d`;
- bundle/signing identifier `com.trycua.lume` and Team ID `YCK386LBJ7`;
- a valid Developer ID signature and the virtualization/networking entitlements;

Only after those checks pass does the bounded probe execute the CLI to require version `0.5.3` and inspect its advertised create, detached-run, attach, storage, and display options.

The installer does not exist in this PR. Its future download path must first check the archive pin `af5d0556763a7f0116153c220aaabe44974e775091ac57e38da2abb2959c63e8`; the helper and digest tests added here do not establish provenance for an app placed manually.

If static verification succeeds, the probe runs only `--version` and help commands. It deliberately does **not** run `lume ls`: pinned 0.5.3 source shows that listing can remove [stale provisioning markers](https://github.com/trycua/cua/blob/754eec754991e1760100621e9bfe7ec1395cc7db/libs/lume/src/LumeController.swift#L174-L184) and [VNC-session files](https://github.com/trycua/cua/blob/754eec754991e1760100621e9bfe7ec1395cc7db/libs/lume/src/LumeController.swift#L216-L230). Lume configuration and temporary writes are redirected to private Guesthouse directories, while telemetry and update checks are disabled.

The runtime repeats static verification immediately before each probe launch and downgrades `verified` if the bundle changed. The containment threat model treats other processes already running as the host user as trusted; a future installer must still replace versioned runtime directories atomically before exposing them to discovery.

These checks do not assess Gatekeeper notarization, boot a VM, prove lifecycle behavior, or make unattended provisioning safe.

Provider-preflight observation: on 2026-09-03, a fresh archive whose digest matched the published 0.5.3 checksum failed both strict Security-framework validation and `codesign --verify --strict` on macOS 26.4.1 (`errSecCSSignatureFailed`, -67061); the packaged installer also reported an invalid signature. Reproduce this first. Do not weaken or bypass validation to continue the experiment—if the published artifact fails, post a failed provider-preflight observation to #82 and request a corrected upstream build. Do not assign a Phase-0 gate status to this observation; `blocked` is not a valid gate status.

## Known 0.5.3 risks to test, not assumptions to accept

- Every run starts Lume's private-API VNC server, including `--display none`; [the pinned CLI says it remains available in every mode](https://github.com/trycua/cua/blob/754eec754991e1760100621e9bfe7ec1395cc7db/libs/lume/src/Commands/Run.swift#L12-L17), and this release has no `--vnc disabled` option.
- [VNC credentials can be written to session state and logs](https://github.com/trycua/cua/blob/754eec754991e1760100621e9bfe7ec1395cc7db/libs/lume/src/VM/VM.swift#L315-L346). [Detached mode defaults to a user Library log](https://github.com/trycua/cua/blob/754eec754991e1760100621e9bfe7ec1395cc7db/libs/lume/src/Commands/DetachedRun.swift#L101-L123) unless `--log-file` is supplied.
- The Tahoe offline setup path creates a [`lume` account with a hard-coded `lume` password](https://github.com/trycua/cua/blob/754eec754991e1760100621e9bfe7ec1395cc7db/libs/lume/src/Unattended/MacOSOfflineSetupPatcher.swift#L111-L125), enables autologin, and enables SSH. Do not expose that guest to an untrusted network or install GitHub/Codex credentials before replacing and disproving those defaults.
- Lume's convenience SSH/shutdown paths do not meet Guesthouse's pinned-host-key and secret-handling requirements. Do not use them as evidence for secure Guesthouse SSH.

## Preconditions

1. Use a backed-up Apple-silicon test Mac with the exact host build recorded.
2. Use a disposable guest and an empty Guesthouse VM store. Put no source code, GitHub token, Codex token, Apple Account, SSH key, or other secret in it.
3. Download the complete app from the [official 0.5.3 release](https://github.com/trycua/cua/releases/tag/lume-v0.5.3). Independently verify the archive SHA-256 above before extraction; preserve the app bundle intact.
4. Build and sign Guesthouse, quit Xcode, and launch that build from Finder. Record Guesthouse commit/signing identity, host build, Lume archive digest, CDHash, and signing identity.
5. Copy the verified complete `lume.app` to the pinned runtime path. Until the GUI installer exists, this one developer-only placement step is manual.

Never paste a VNC URL, password, token, raw Lume session file, or raw detached log into an issue or evidence record.

## Procedure

### A. Signed app and XPC probe

If the independent signature preflight fails, stop here and post a failed provider-preflight observation to #82; the remaining steps are conditional procedures for a corrected artifact.

1. In the Finder-launched Debug build, choose **Debug → Runtime Version**.
2. Confirm the service replies immediately with either `checking` or a completed result. After discovery finishes, request it again without relaunching the app or runtime service. Confirm it reports Lume `0.5.3`, `verified`, and every CLI capability: unattended Tahoe, create/run/attach storage, detached run, and native attach must each be `available`; VNC disable is expected to be `unavailable` for this pin. Record any other unavailable or not-checked capability as an incomplete or failed preflight, not a successful verified result. `verified` covers the pinned executable, not CLI capabilities or hardware gates.
3. Quit Guesthouse and confirm its embedded runtime service exits before each remove/corrupt/restore mutation, then relaunch the signed app for a fresh discovery. Confirm missing/damaged states report the error and its declared recovery choices, and that no rejected executable runs. These choices are diagnostic text in this revision, not wired buttons; do not claim the repair action itself was tested.
4. Confirm all probe writes stay below Guesthouse's private `state/lume-xdg` and `staging` directories. Record startup/probe duration and whether the UI or XPC connection times out.

### B–D. Deferred lifecycle acceptance checklist

Stop after section A in this revision. This checkout has no approved operation that creates, starts, attaches to, stops, or deletes a Lume VM. Do not invoke Lume directly, improvise a shell script, or repurpose the non-mutating capability probe: each would bypass the verified, named-operation boundary required by [MVP-PLAN.md §3, “Sandbox and XPC boundary”](../../MVP-PLAN.md#sandbox-and-xpc-boundary). Sections B–D are acceptance criteria for a later hardware-enabled change, not runnable instructions.

Before running this checklist, a separate reviewed PR must add a named, bounded RuntimeKit-backed lifecycle diagnostic, its typed XPC operation, and a signed Debug-menu operator surface. That diagnostic must:

- accept only a validated environment ID and a user-selected IPSW access grant; the service chooses the pinned executable, VM name, storage path, environment, working directory, and fixed argument arrays;
- repeat managed-path and full bundle verification immediately before every launch, and hold `LumeRuntimeCoordinator`'s exclusive lease across each lifecycle transition;
- pass the private VM store explicitly to every applicable command, disable telemetry/update checks, set a private detached log path, forbid host shares, and inherit neither `HOME` nor `PATH`;
- bound runtime and output, redact all output before it crosses XPC, journal mutations, and reconcile an interrupted or timed-out operation before permitting another mutation;
- expose attach and graceful-stop as separate named operations, never use Lume's password-bearing convenience shutdown, and require explicit confirmation before the known stopped disposable VM can be deleted; and
- have unit tests proving the exact executable, arguments, environment, paths, timeouts, output limits, cancellation behavior, and refusal of unsafe storage or a changed bundle.

Do not begin the lifecycle run merely because a developer can construct equivalent command-line arguments. Until that diagnostic lands and the published Lume artifact passes the signature preflight, this revision cannot pass the candidate decision below.

#### B. Disposable unattended guest

1. Only if signature preflight passes, use the approved lifecycle diagnostic to create one fresh Tahoe guest unattended in the explicit Guesthouse-private VM store. Do not use a shared directory.
2. Record first-boot duration, disk growth, peak memory, console interventions, and every path written outside the approved runtime tree.
3. Before enabling any provider login, change the account name/password and disable autologin as the product design requires. From a separate pinned OpenSSH connection, prove the original `lume`/`lume` login no longer works after a cold boot. If it still works, mark the provider preflight failed.

#### C. Storage and lifecycle

1. Exercise the diagnostic's named create, inspect, inventory, detached-run, attach, stop, and confirmed-delete operations. Confirm their fixed invocations all use the explicit private storage path and no default Lume VM store is read or changed.
2. Start detached with display `none` and an explicit private log path. Close the initiating Guesthouse window without quitting the app; verify a build in the guest continues.
3. Attach the native display, close it, and attach again. Viewer close must not stop the guest or its build. Record what happens when Guesthouse quits and when it is force-quit; do not infer ownership from a surviving PID alone.
4. Perform a graceful guest shutdown over separately host-key-pinned OpenSSH, then use Lume only to observe/finish lifecycle state. Test forced stop separately and check disk integrity after boot.
5. Put the host to sleep during a build. On wake, reconcile process identity, VM state, networking, SSH host key, build outcome, and attach behavior before starting anything new.

#### D. VNC containment

1. While the guest runs with display `none`, record every listening socket, interface, and owning process created by Lume.
2. Confirm whether VNC is reachable from another host and another local account. Treat any nonessential exposure as a failed provider preflight, not a documentation follow-up.
3. Inspect private session/config/log files for VNC URLs and credentials without copying their values. Record only file paths, permissions, and a yes/no presence result.
4. Confirm diagnostic export excludes raw Lume logs/session data. If 0.5.3 cannot contain the always-on VNC surface and its credentials acceptably, record a no-go or require a newer pinned release before integration.

## Decision

This revision can record only the signed XPC observation in section A. It cannot pass the full candidate decision while sections B–D lack the approved diagnostic or while the pinned official artifact fails strict signature validation.

Pass this candidate only when the signed XPC path works, all lifecycle commands honor private storage, detach/reattach and sleep recovery are reproducible, initial credentials are eliminated before secrets arrive, and VNC exposure/secret storage meet the threat model. Otherwise record the precise failure and choose one of: pin a fixed Lume release, carry a narrowly reviewed upstream fix, return to Tart, or build the required Virtualization.framework slice directly.

After the run, post the exact versions, Guesthouse commit, redacted evidence, and conclusion to #82. If maintainers select Lume, record that provider decision in an ADR and update `MVP-PLAN.md` plus the Phase-0 gate registry/template before writing formal gate evidence.
