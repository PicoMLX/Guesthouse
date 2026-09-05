# Working on Guesthouse

Guesthouse is a native macOS app that prepares an isolated development Mac (a macOS VM run by Tart), connects it to the Codex desktop app, and manages multi-repository Xcode workspaces inside that VM. The developer never needs Terminal, Homebrew, or a hand-written SSH configuration. `MVP-PLAN.md` is the specification; cite its section when a change interprets it.

## Layout

| Path | What it is | Rules |
| --- | --- | --- |
| `Guesthouse/` | The SwiftUI app. App Sandbox and Hardened Runtime on. Product name is "Guesthouse Codex VM". | UI state is `@MainActor` (the target sets MainActor default isolation). Never launches processes. |
| `GuesthouseRuntime/` | Embedded XPC service, non-sandboxed, Hardened Runtime on (added by issue #19). | The only place host operations run. Exposes named operations, never a generic "run a command" API. |
| `Packages/GuesthouseCore` | Shared models, typed XPC contract, state machines, parsers, validation. | Nonisolated by default; every public type is `Sendable`. No process execution, no host mutations. |
| `Packages/GuesthouseRuntimeKit` | Process execution and Tart adapters (added by issue #21). | Linked only by `GuesthouseRuntime`. The app target must never import it. |
| `Fixtures/` | Sample app and package repositories used inside the guest VM by the phase-0 gates. | Not part of the product. Excluded from CI. |
| `docs/phase0/` | Recorded results of the phase-0 hardware experiments. | Only filled in from a real run. Never from reasoning. |
| `docs/decisions/` | Architecture decision records. | One file per decision. |

## Commands

All package tests with the CI warning policy (fast, no signing):

```bash
./ci_scripts/ci_pre_xcodebuild.sh
```

One package:

```bash
swift test --package-path Packages/GuesthouseCore -Xswiftc -warnings-as-errors
```

One package test:

```bash
swift test --package-path Packages/GuesthouseCore --filter coreModuleIdentity -Xswiftc -warnings-as-errors
```

App build and tests through the shared scheme (also runs the package tests):

```bash
xcodebuild -project Guesthouse.xcodeproj -scheme Guesthouse -destination 'platform=macOS' test -skip-testing:GuesthouseUITests
```

One app test:

```bash
xcodebuild -project Guesthouse.xcodeproj -scheme Guesthouse -destination 'platform=macOS' test -only-testing:GuesthouseTests/GuesthouseTests/example
```

Open in Xcode with `open Guesthouse.xcodeproj`. Xcode 26.6 or later, macOS 26.4 or later.

## Continuous integration and review

Xcode Cloud runs the `Guesthouse` scheme's Test action on pull requests to `main` and reports a check to GitHub. Keep the scheme's Test action as the source of truth for Xcode tests; when you add a package, add its test target to the shared scheme. Codex reviews every pull request automatically.

The executable `ci_scripts/ci_pre_xcodebuild.sh` additionally runs every immediate `Packages/*/Package.swift` package with warnings treated as errors, independently guarding against missing scheme coverage (issue #2; `MVP-PLAN.md` §11). It uses `CI_PRIMARY_REPOSITORY_PATH` in Xcode Cloud and its own repository location locally, excludes `Fixtures/`, and fails if no packages are found. It skips only `test-without-building`: [Apple documents that phase as having no source checkout](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions); package tests have already run during `build-for-testing`.

Validate hook discovery, paths with spaces, phase handling, and failure propagation without compiling Swift:

```bash
bash Tests/CI/test-package-hook.sh
```

## Conventions

- Swift 6 language mode everywhere. Zero new warnings.
- Core package types are `Sendable` and nonisolated. Do not add `@MainActor` to core types.
- No third-party dependencies. If one seems necessary, open an issue that justifies it first.
- Launch processes only in the runtime service or `GuesthouseRuntimeKit`, always with an executable URL and an argument array. Never `/bin/sh -c`, never string interpolation into a command, never an inherited environment.
- The service chooses executable paths and flags. Requests from the GUI carry environment IDs and validated options, never paths to run or Tart flags.
- Treat guest output, repository content, branch names, file names, and CLI text as untrusted data. Never turn any of it into a host command.
- Never log or persist tokens, passwords, device codes, private keys, or authorization headers. Route every log line through the redaction layer once it exists (issue #11).
- Prefer environment UUIDs and relative guest paths over IP addresses as persistent identity.
- An interrupted operation has an unknown outcome until the actual state is inspected. Never retry a mutating operation blindly.
- Errors carry a user-facing message and at least one recovery action. "Something went wrong" is never the only information.

## Picking work

Issues labeled `agent-ready` are self-contained and CI-verifiable; pick one whose dependencies are closed. Issues labeled `needs-hardware` are experiments a person runs on the reference Mac. Do not attempt them, do not close them, and never write their `docs/phase0/` record from reasoning. Issue #48 lists the order of work.

## Definition of done

- Tests cover the new logic and the package or app test command above passes locally.
- CI is green and the automated review has no unaddressed findings.
- No new warnings, no new third-party dependencies (local packages and system frameworks are fine when an issue calls for them), no secrets in code, logs, or tests.
- The pull request links its issue and cites the `MVP-PLAN.md` section it implements.
- Keep a pull request under roughly 500 changed lines; split it otherwise.
