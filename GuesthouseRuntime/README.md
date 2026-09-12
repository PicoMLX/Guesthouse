# Check the runtime caller boundary

Use this manual procedure to attempt the current read-only runtime query from a client without a development-team signature. It completes the procedure requested by [issue #20](https://github.com/PicoMLX/Guesthouse/issues/20), implementing [MVP-PLAN.md](../MVP-PLAN.md) §§3 and 11. It is **not a recorded test result**. A person runs the experiment for [gate #34](https://github.com/PicoMLX/Guesthouse/issues/34); no phase-zero gate passes because this README or the package tests exist.

## Prepare a signed positive control

Use macOS 26.4 or later and Xcode 26.6 or later, with development signing available for the repository's configured team. Work on a disposable test account with no Guesthouse credentials or valuable app-container data: the copied client retains the app identifier and sandbox entitlements, so it is not a separate data environment. This procedure changes only a disposable app copy. Never re-sign the installed app, alter the listener policy, export signing keys, or disable macOS security protections to make the experiment run.

1. In Xcode, build and run the `Guesthouse` scheme from `Guesthouse.xcodeproj`, with normal development signing. Do not use a signing-disabled CI product. Record the commit, macOS/Xcode versions, and build configuration.
2. Click **Check runtime connection**. Require **Runtime service responded.** and the displayed version/build/protocol. This only queries the embedded service; it does not start a VM or verify a provider. If this fails, stop: there is no working positive control yet.
3. Quit Guesthouse. In Xcode's Products group, show **Guesthouse Codex VM.app** in Finder. In Terminal, set `signedApp` to that exact built product's absolute path, replacing the example below. Inspect both signatures:

   ```bash
   signedApp='/absolute/path/to/Guesthouse Codex VM.app'
   signedService="$signedApp/Contents/XPCServices/GuesthouseRuntime.xpc"
   /usr/bin/codesign --verify --deep --strict --verbose=2 "$signedApp"
   /usr/bin/codesign --display --verbose=4 "$signedApp"
   /usr/bin/codesign --display --verbose=4 "$signedService"
   ```

   Stop on any verification failure. Require app identifier `com.starlingprotocol.Guesthouse`, service identifier `com.starlingprotocol.Guesthouse.Runtime`, and the same nonempty `TeamIdentifier` on both (the project currently configures `TPKP4XK352`). Record each `CDHash`. Displaying metadata alone does not verify a signature.

## Make the scratch client

The scratch client is a copy of the real GUI with **only its outer app signature** replaced by an ad-hoc signature. It keeps the current native dictionary/frame/envelope implementation and the embedded, development-signed service. This avoids mistaking a standalone CLI's inability to discover a bundle-private service for an authentication rejection. Apple describes the service's [bundle-private scope](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html).

1. In the same Terminal session, create a new temporary directory and copy the app. Run each step only after the preceding command succeeds:

   ```bash
   scratchRoot=$(/usr/bin/mktemp -d /private/tmp/guesthouse-caller.XXXXXX)
   scratchApp="$scratchRoot/Guesthouse Codex VM.app"
   /usr/bin/ditto "$signedApp" "$scratchApp"
   scratchService="$scratchApp/Contents/XPCServices/GuesthouseRuntime.xpc"
   /usr/bin/codesign --verify --deep --strict --verbose=2 "$scratchApp"
   /usr/bin/codesign --display --verbose=4 "$scratchService"
   ```

   Require the copied service's team, identifier, and `CDHash` to match the original. Keep the original product untouched.
2. With the original app stopped, open the copy from its temporary folder in Finder. Confirm the running app's executable path belongs to this copy, using Activity Monitor's process inspection or Xcode's debugger. Click **Check runtime connection** and require the same successful response. Verify the service's executable path when the query launches it; if necessary, configure Xcode's debugger to wait for that service's launch before running the query. Do not require the on-demand service to exist before clicking the button. Then quit the copy and confirm its processes have exited. A failed copied positive control makes this experiment inconclusive; do not proceed.
3. Re-sign only the copied outer app:

   ```bash
   /usr/bin/codesign --force --sign - \
     --preserve-metadata=identifier,entitlements,flags,runtime "$scratchApp"
   ```

   Do **not** add `--deep` here or separately re-sign `scratchService`. The listener's same-team requirement uses the service's actual signing team. Making the service ad-hoc too would change the verifier, not only the caller. Apple also warns against [deep signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac). The local `man codesign` documents `--sign -` and the preserved metadata fields.
4. Verify the changed client and unchanged service separately:

   ```bash
   /usr/bin/codesign --verify --deep --strict --verbose=2 "$scratchApp"
   /usr/bin/codesign --display --verbose=4 "$scratchApp"
   /usr/bin/codesign --display --entitlements - "$scratchApp"
   /usr/bin/codesign --verify --strict --verbose=2 "$scratchService"
   /usr/bin/codesign --display --verbose=4 "$scratchService"
   ```

   Require an ad-hoc outer signature with no development `TeamIdentifier`, the unchanged app identifier, App Sandbox entitlement still enabled, and the hardened-runtime flag still present. The service must retain its original team, identifier, and `CDHash`. Stop if any condition differs. On Apple silicon, this tests a client without a developer identity, not necessarily an executable with no code signature at all. A structurally valid signature does not guarantee macOS will permit launch.

## Attempt the unauthorized query

1. Open the ad-hoc copy from its exact temporary path, with all other Guesthouse instances stopped. Confirm the caller's executable path before clicking **Check runtime connection**. Confirm the service path too if macOS starts it. Do not rebuild through Xcode between signature checks and launch; that would restore the development signature.
2. Observe the query result. The expected negative result is **no successful runtime-version reply**. The GUI may present a fixed connection failure or timeout rather than an unauthorized-caller reply, because the listener can reject the session before the message handler runs.
3. Corroborate the reason before claiming authentication passed: inspect the relevant XPC rejection in Console or the service boundary in Xcode's debugger, without changing its requirement or injecting an authentication result. Attribute the evidence to the copied caller/service and this attempt. A timeout, failure to launch, missing service, or absence of a breakpoint hit **alone is inconclusive**, not proof of caller rejection. If macOS blocks the ad-hoc app before XPC, record that limitation and stop; do not disable Gatekeeper, SIP, sandboxing, or other protections.
4. Quit the copy. Launch the untouched original and repeat the successful connection check. If the final positive control fails, investigate the environment before attributing the negative result to caller authentication.

Classify the attempt using these criteria:

| Observation | Result |
| --- | --- |
| All positive controls succeed; only the caller loses its team signature; evidence identifies XPC caller-authentication rejection; no successful query reply | Caller-rejection proof passes for this tested build |
| The ad-hoc client receives a successful runtime-version reply from the preserved service | Caller-rejection proof fails; preserve evidence and fix the boundary |
| Launch/routing/verification fails, a control fails, or the rejection cause cannot be attributed | Inconclusive; no boundary proof or gate pass |

Record the versions/commit, all query outcomes, app/service identity comparisons, relevant fixed rejection evidence, and limitations in the human-run gate record using the [phase-zero instructions](../docs/phase0/README.md). Do not upload general Console exports, authentication transcripts, or unrelated private data. The listener may reject before Guesthouse emits a typed diagnostic; do not invent an expected OS log string or add raw-error logging to obtain one. After preserving the needed evidence, move only the disposable `guesthouse-caller.…` folder to Trash in Finder.

This procedure covers one caller-identity case. It does not complete gate #34's other requirements, demonstrate a wrong-identifier/same-team case, or prove both authentication layers independently. If the listener rejects first, per-message authentication has not been exercised by this attempt.

## Locate the implementation and software tests

- [Service entry point](Sources/main.swift) installs the fixed listener requirement. [RuntimeCallerAuthentication](../Packages/GuesthouseRuntimeKit/Sources/GuesthouseRuntimeKit/RuntimeCallerAuthentication.swift) also checks the original incoming dictionary; there is no caller-selected identity or PID-based trust.
- [NativeRuntimeRequestHandler](../Packages/GuesthouseRuntimeKit/Sources/GuesthouseRuntimeKit/NativeRuntimeRequestHandler.swift) authenticates before payload decoding and exposes only the read-only version query in its production constructor. [RuntimeVersionQuery](../Packages/GuesthouseClientKit/Sources/GuesthouseClientKit/RuntimeVersionQuery.swift) is the GUI's actual client path.
- Core and native package tests cover malformed/bounded frames, mandatory version envelopes, admission, reply ownership, and injected authentication decisions. Xcode Cloud runs the package hook and shared scheme. These tests do not substitute for the signed Finder-launched app experiment.
