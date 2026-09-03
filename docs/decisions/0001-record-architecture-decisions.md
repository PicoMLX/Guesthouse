# 1. Record architecture decisions

Date: 2026-09-03

## Status

Accepted

## Context

`MVP-PLAN.md` §10 ("Deliver in six phases") leaves several choices to be settled by the phase-0 gates, such as the Xcode import transport, the console path, and how cold-boot authentication is implemented through the guest Keychain, and it warns that a gate result may require re-estimating or changing the architecture. What is settled by a gate is the approach, never whether a mandatory requirement applies: §10 requires both providers to authenticate through the guest Keychain after a cold boot, and requires an authentication failure to be resolved rather than waived. Those outcomes need a durable place that is separate from the plan and from issue threads, so that later work can see what was decided, when, and on what evidence.

## Decision

Keep architecture decisions as short records in `docs/decisions/`, one file per decision, with sections Status, Context, Decision, and Consequences. Records are immutable once accepted; a new record supersedes an old one and links to it.

## Consequences

Every phase-0 gate record that settles a design question also produces an ADR. Pull requests that change a recorded decision must add a superseding record rather than editing the original.
