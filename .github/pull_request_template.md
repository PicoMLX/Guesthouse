## Summary

<!-- What changed and why. Cite the MVP-PLAN.md section when this interprets the plan. -->

Closes #

## Checklist

- [ ] Tests cover the new logic; `swift test --package-path Packages/GuesthouseCore` and the app test command in `AGENTS.md` pass locally
- [ ] No new warnings
- [ ] No new dependencies
- [ ] No secrets, tokens, device codes, or key material in code, logs, fixtures, or tests
- [ ] No process launched outside the runtime service or `GuesthouseRuntimeKit`; no shell interpolation anywhere
- [ ] Docs updated where behavior or commands changed
- [ ] Diff is under roughly 500 lines, or the split is explained above
