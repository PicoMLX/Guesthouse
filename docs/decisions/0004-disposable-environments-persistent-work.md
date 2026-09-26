# 4. Keep task files across Stop and Start

Date: 2026-09-26

## Status

Accepted by the owner for MVP lifecycle and persistence scope. Implementation and human validation remain pending.

## Context

Guesthouse provides an interactive development Mac for agent work. A developer may stop it to free memory and return later with uncommitted changes or unpushed commits still inside the guest. Treating every boot as a fresh job would make Stop destructive and require reliable output collection before every shutdown.

The owner selected environments that are disposable when work is finished and retain task files while work continues. This clarifies [MVP-PLAN.md](../../MVP-PLAN.md) §§1–3, 9–11. It does not select a provider or record a hardware result. [ADR 0002](0002-prioritize-lume-and-shared-infrastructure.md) and [ADR 0003](0003-structured-diagnostics.md) remain in force.

## Decision

- **Stop** gracefully shuts down the guest and retains its existing VM disk, installed tools, repositories and saved files. **Start** boots that same environment and rechecks readiness. Normal Quit uses the same stop behavior.
- A clean workspace or environment is an explicit new-work choice. Starting another agent task does not automatically reset an existing environment. Multiple workspaces may continue to share one environment.
- **Start fresh** means an explicit discard-and-create flow with the same unpublished-work protection as **Delete environment**. Warn before destruction, offer export or preservation, and require an explicit discard choice when work is unexported or cannot be verified. A completed agent task, successful build or published PR alone never authorizes deletion.
- Reuse the verified setup procedure and approved installation artifacts to prepare tools. Baseline reuse does not require a template/clone subsystem, an account-bearing shared image or a hidden extra bootable VM. The existing two-bundle cap includes stopped and recovery-preserved environments.
- Running builds, Simulator sessions and agent processes may terminate on Stop. Process resumption, VM memory-state restoration, continuous execution after a crash and lossless power-failure recovery are not MVP promises. Unsaved work may be lost; interrupted operations may need manual repair.
- After interruption, preserve the existing disk and inspect actual ownership, VM and operation state. Refuse uncertain mutations; never double-start a disk, silently recreate an environment or blindly repeat a push or PR creation.
- Keep one runtime-owned metadata writer with an exclusive lock on its private state directory, versioned records, atomic metadata replacement and minimal operation tracking. A second runtime cannot mutate that state concurrently. Detect write failures before reporting success; corrupt or unsupported records are preserved for explicit repair. A bounded partial journal tail can require inspection rather than automatic repair.
- The metadata store does not defend against deliberate modification of its private files by another process running as the same host user. Ordinary I/O failures, cooperating runtime contention, access protection and host/guest boundary validation remain in scope. Existing symlink/path protections are not removed by this decision.

## Consequences

Retaining guest files requires keeping the VM disk across normal shutdown; it does not require reconstructing guest source files from Guesthouse's metadata journal. Persistence work must serve this bounded contract rather than add general history-reconstruction, shared-owner observation or same-user tamper resistance.

Review the existing #8/#76 persistence work against this scope. Preserve useful code and findings; this decision neither merges nor closes a PR, proves an existing implementation correct, nor authorizes blanket removal of its tests. Runtime integration remains unfinished.

Validate saved uncommitted edits, untracked/ignored files and unpushed commits across normal Stop/Start on the same environment, without repeating tool/account setup. Separately validate disk preservation and refusal of duplicate or uncertain mutations after interruption. These checks establish safe reopening, not continued execution or lossless power-failure recovery. Human gates remain unrun until evidence is recorded under the accepted provider's procedures.
