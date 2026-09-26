# Architecture decision records

One file per decision, numbered in order: `NNNN-short-title.md`. A record is never edited after acceptance; a later decision supersedes it and links back. Use the format in [0001-record-architecture-decisions.md](0001-record-architecture-decisions.md).

Decisions that come out of the phase-0 gates (supported builds, Xcode transport, console path, cold-boot authentication, supported project shape, resource presets) each get a record.

Owner-approved product scope is also recorded here. [ADR 0004: Keep task files across Stop and Start](0004-disposable-environments-persistent-work.md) defines explicit environment disposal and bounded recovery; it records no hardware result.
