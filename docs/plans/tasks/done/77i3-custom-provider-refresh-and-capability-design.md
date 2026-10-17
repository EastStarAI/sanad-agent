---
title: "Task 77I3: Provider catalog refresh and custom capability design"
status: "superseded"
current_gate: "Moved to standalone main-based provider-composer-catalog-and-custom-thinking-repair task"
remaining_estimate: "Not applicable — no implementation dispatched under this task"
depends_on: "77I2; provider-setup and thinking-control contracts"
---

# Goal

Make composer provider names reflect successful provider creation/rename/removal without restarting the Client. Separately investigate custom-provider image/thinking capability gaps and obtain explicit user approval for any substantial capability architecture before implementing it.

## Execution ownership

The orchestrator owns diagnosis, task gates, diff review, independent test verification, user decision checkpoints and live interactions. The delegated agy implementer owns production/test code edits and fixes returned review findings. Each implementation uses an isolated Git worktree. No commits, pushes, merge, deployment, runtime source handoff or cleanup without separate user authorization.

## Known evidence and boundaries

- User added custom OpenAI Compatible and Anthropic Compatible instances; display names appeared after Client restart, while thinking stayed Unavailable.
- Current provider-name resource owner returns an existing nonempty per-device catalog without revalidation; investigate exact mutation/event invalidation wiring before selecting a fix.
- Current custom thinking policy resolves unknown and uses provider defaults. This is different from a model being unable to reason.
- 77I2 enables Chat image input only for exact known provider/model catalog evidence and an owned endpoint. A custom instance intentionally cannot inherit that authority by display name or model-name guesses.
- User's Anthropic Compatible visual test succeeded, while custom OpenAI-compatible omitted the image. Neither result proves custom thinking-control support.
- Never enable unknown image/thinking capabilities by guessed model names or protocol alone. No secrets, identities or raw provider payloads in reports.

## Gates

### G0 — Triage and bounded delegation
- [x] Separate stale composer names from custom thinking-policy and image-capability design gaps.
- [x] User requests orchestrator/reviewer workflow, agy gemini-3.8-flash-high, explicit permission bypass and supervisor-based dispatch.
- [x] Preserve source WIP as an immutable seed baseline for delegated review; only post-seed changes count as task implementation.

### G1 — Catalog repair and proposal
- [ ] Implementer reads closest contracts and verifies the exact stale-name invalidation boundary.
- [ ] Add failing-before regression for create/rename/removal freshness without rebuild-driven repeated requests.
- [ ] Repair catalog mutation/event invalidation through the existing resource owner; preserve device isolation, shared in-flight requests and stale-response guards.
- [ ] Return a capability architecture proposal covering custom OpenAI-compatible image input and custom thinking controls: authority, storage/schema/UI effects, model scoping, endpoint changes, backward compatibility and safe fallback. No capability implementation yet.
- [ ] Update closest owning docs/contracts only for changed invariants; bounded analyzer/focused tests pass.

### G2 — Independent review
- [ ] Orchestrator reviews only post-seed diff, reruns gates and returns concrete defects to the implementer.
- [ ] Fixes pass independent verification; no unrelated Plan 77 WIP changes or primary mutations.
- [ ] Present material custom capability decisions to user and wait for approval before implementing them.

### G3 — Orchestrator live acceptance
- [ ] Accepted catalog patch reaches the selected Plan 77 test source without runtime source switch or unrelated WIP replacement.
- [ ] Orchestrator validates provider creation/rename/removal names update without Client restart; any durable test-provider mutation is agreed with the user.
- [ ] No extra requests on identical rebuilds; other devices/clients retain their own catalog.
- [ ] Update gates, remaining estimate and graph/doc evidence honestly. Custom image/thinking remains open until separately approved and verified.

## Acceptance criteria

- New/renamed provider display names are correct in composer without restart, and removed providers do not survive in the catalog.
- Explicit catalog changes invalidate stale pending responses and refresh the same resource owner, not widget-build fetch loops or parallel state owners.
- Rebuild/remount sharing and device separation remain intact.
- No capability schema, defaults or compatibility semantics change under the guise of a refresh bugfix.

## Initial progress

Superseded before dispatch by the user's approved split: image work remains in Plan 77; provider-name freshness and custom thinking now belong to one main-based worktree/task/PR, owned by `docs/plans/tasks/provider-composer-catalog-and-custom-thinking-repair.md` in that public branch. No worker was launched for this old packet; no catalog/thinking implementation is claimed here. The earlier seeded child worktree was removed on explicit user request after verifying zero post-seed changes and zero matching runtime processes; active Plan 77 and main-based provider-repair worktrees were preserved. Parent Plan 77 remains open.
