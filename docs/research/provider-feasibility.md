# Preliminary provider feasibility

This is the canonical record designated by ROADMAP.md, the phase-zero registry and MVP-PLAN.md §10. Records distinguish automated static artifact checks from human runtime, guest Codex connectivity and native MLX/GPU experiments. None establishes provider acceptance or a formal gate result.

| Date (UTC) | Candidate | Operator and scope | Evidence | Remaining proof |
| --- | --- | --- | --- | --- |
| October 5, 2026 | Lume 0.6.1, arm64 | Codex, automated assistant in the Guesthouse chat; downloads, bounded extraction and static signature/notarization checks on arm64 macOS 26.6.2 (25G83) | [Exact 0.6.1 artifact identities and measured checks](lume-0.6.1-artifact-review.md) | Current verifier/probe integration, reviewed human provider preflight, credential/console protections, actual guest connectivity and MLX/GPU evidence, provider-selection decision and formal gates |
| October 1, 2026 | Lume 0.6.0, arm64 | Codex, automated assistant in the Guesthouse chat; downloads, bounded extraction and static signature/notarization checks on arm64 macOS 26.6.2 (25G83) | [Exact artifact identities and measured checks](lume-0.6.0-artifact-review.md) | Current verifier/probe integration, reviewed human provider preflight, actual guest connectivity and MLX/GPU evidence, provider-selection decision and formal gates |

The linked record contains the release source revision, measured archive and executable digests, checks, host tuple and limitations. No provider code or installer was executed. The earlier Lume 0.5.3 rejection remains historical evidence in [issue #82](https://github.com/PicoMLX/Guesthouse/issues/82); a later static pass does not authorize running those rejected bytes. Production VM mutations remain disabled pending their prerequisites.
