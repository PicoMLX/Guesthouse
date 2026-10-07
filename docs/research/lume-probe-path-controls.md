# Lume probe path controls

Static source audit for #82/#283 and retained #84 under MVP-PLAN.md §§3, 4 and 9, ADR0002/0004. This records recognized path controls; it is not execution, provider adoption or containment proof.

The measured 0.6.1 release declares source revision `3350f504014c85416009a90fcb339fe556ce02fc` ([artifact record](lume-0.6.1-artifact-review.md)). At that revision:

- [SettingsManager](https://github.com/trycua/cua/blob/3350f504014c85416009a90fcb339fe556ce02fc/libs/lume/src/FileSystem/Settings.swift) recognizes `XDG_CONFIG_HOME` and appends `lume/config.yaml`. It can create that directory and save defaults during settings access.
- [ReleaseChannel](https://github.com/trycua/cua/blob/3350f504014c85416009a90fcb339fe556ce02fc/libs/lume/src/Update/ReleaseChannel.swift) recognizes `LUME_HOME` for its `release-channel` file.
- Settings defaults still refer to `~/.lume` for VM/cache placement. [TelemetryClient](https://github.com/trycua/cua/blob/3350f504014c85416009a90fcb339fe556ce02fc/libs/lume/src/Telemetry/TelemetryClient.swift) resolves its separate default home through Foundation. `LUME_HOME` is not a universal home override. Telemetry consent checks honor `LUME_TELEMETRY_ENABLED=false`; that flag is not a filesystem containment mechanism.

Guesthouse prepares and rechecks both `state/lume-xdg` and `state/lume-xdg/lume`, using the existing storage protection and StateStore owner/lease. Its fixed probe environment binds the XDG root to the former and release-channel state to the latter. Preparation preflights both existing entries before repairing either one, preserving contents and parent metadata when an unsafe child is refused. Each preparation retains its own rechecks; this is not an atomic tree transaction. Cancellation is checked again on final StateStore actor entry before creating or repairing either directory.

These paths support preparation for the separately reviewed, fixed version/help diagnostics. They do not authorize VM commands, relocate every provider path, validate provider-created file modes, prove descendant quiescence or establish runtime readiness. Provider execution remains held behind strict artifact verification, owned-process/storage and candidate-specific containment prerequisites. The rejected historical0.5.3 pin is unchanged. A changed candidate must have its actual source/path behavior rechecked; this snapshot is not durable launch authority.

Tests inspect real temporary directories and typed refusal/cancellation outcomes. They do not run Lume, its wrapper/installer or a VM. Full fork/restart/provider reconciliation, explicit metadata repair, credentials/VNC/GPU, provider selection and human gates remain open.
