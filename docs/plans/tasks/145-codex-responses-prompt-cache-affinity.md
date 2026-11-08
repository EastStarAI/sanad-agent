---
title: "Codex Responses prompt-cache routing affinity"
status: "in progress"
current_gate: "G2 verification — fixture matrix green; Draft PR #356 delivered; live cached-token gate blocked pending an owner-authorized isolated Codex route"
remaining_estimate: "live cached-token evidence only"
---

# Goal (Task 145)

Retain the OpenAI Responses prompt cache on the `openai-codex` route across a
conversation instead of flapping between warm cache shards and cold misses.
The request must carry a stable routing key while the static request material
stays unchanged, and endpoint-specific schema quirks must not turn that hint
into a dispatch failure.

## Evidence (pre-change)

- Owner-provided request dumps show stable `instructions` and `tools` hashes
  and strict prefix extensions across consecutive Codex requests.
- The same dumps show `input_tokens_details.cached_tokens` flapping between
  zero and large values, which is consistent with requests landing on
  different cache shards when no routing affinity is sent.
- The field was absent from the agent source history; this is a missing
  feature, not a regression.
- The transferred patch excluded xAI and GitHub hosts. Official xAI
  documentation for prompt caching describes `prompt_cache_key` as a raw
  Responses HTTP body field, and Sanad sends raw JSON, so the xAI exclusion is
  incorrect. GitHub-hosted Responses endpoints remain excluded by the owning
  endpoint policy.
- No verified evidence supports describing the implementation as parity with
  another agent; that wording was removed.

## Locked decisions

- The key is content-addressed from the stable session scope, instructions,
  and name-sorted tools. It is never derived from conversation history, so a
  strict prefix extension cannot rotate it.
- The wire shape is `pck_<sha256[:24]>`, at most 64 characters, with a stable
  hash for over-long inputs.
- GitHub-hosted Responses endpoints (`api.github.com`, `github.ai`,
  `githubcopilot.com`) drop the field before dispatch. Matching is exact or
  dot-suffix so lookalike domains are not excluded.
- xAI keeps the body field; only the `chatgpt.com` Codex backend receives
  `session_id` and `x-client-request-id`, and the header value mirrors the
  exact body key with no fallback.
- Sync and stream reuse the same request builder and header composition.
- No runner/history changes, no `cache_control`, and no behavior change for
  Chat, Anthropic Messages, or Ollama routes.
- Live evidence must come from an owner-authorized isolated authenticated
  Codex route. Credential copying, the primary Home, occupied Test Homes, and
  runtime switching are out of scope.

## Gates

### G0 — Discovery
- [x] Confirm the pre-change dump evidence: stable instructions/tools, strict
  prefix extension, and flapping cached-token counts.
- [x] Confirm the field was never implemented in the agent source history.
- [x] Verify xAI prompt-cache documentation: `prompt_cache_key` is accepted in
  the raw Responses body.
- [x] Verify the transferred diff matches the owner's original patch.
- [x] Identify the GitHub-hosted Responses endpoints that must keep the field
  excluded.
- [ ] Live cached-token baseline from an authorized isolated Codex route
  (blocked; see G2).

### G1 — Implementation
- [x] `codex_responses_codec.dart`: build the bounded content-addressed key
  from scope, instructions, and name-sorted tools; keep it independent of
  history and stable for over-long inputs.
- [x] `codex_responses_policy.dart`: own the GitHub-only exclusion with exact
  and dot-suffix matching; keep xAI and other hosts supported.
- [x] `codex_responses_adapter.dart`: send `session_id` only when a raw
  session id exists, mirror the exact body key in `x-client-request-id`, and
  apply both to sync and stream through the shared header path.
- [x] Remove unverified parity wording and the stale xAI comment from code and
  contracts.
- [x] Rewrite the focused test group with valid tool schemas, sync/stream
  dispatch, policy coverage, xAI/GitHub/OpenAI host coverage, history
  stability, content rotation, ordering stability, scope separation, bounds,
  and null-session behavior.
- [x] Update `agent/lib/engine/adapters/AGENTS.md` and the Codex Responses
  runtime design with the corrected host policy.
- [x] Add the QA matrix page and index it in `docs/llms.txt`.

### G2 — Verification
- [x] `fvm dart analyze` clean for the changed source and test files.
- [x] `fvm dart test test/engine/adapters test/guards/file_size_ratchet_guard_test.dart --reporter expanded`
  green: 298 tests.
- [x] `git diff --check` clean after final edits.
- [x] `graphify update .` after the source edits.
- [x] Draft PR #356 created with `type/feature`, `comp/agent`,
  `comp/providers`, and `size/medium`; implementation-head CI green and the
  PR re-queried for Draft state, head, labels, and checks.
- [ ] Live cached-token before/after evidence: blocked pending an
  owner-authorized isolated authenticated Codex route.

## Acceptance criteria

- A strict prefix extension keeps the same key in both sync and stream.
- Instructions, tool set, tool schema, or tool name changes rotate the key.
- Tool list order and schema map insertion order do not rotate the key.
- xAI and ordinary OpenAI bodies carry the key without Codex-only headers.
- GitHub-hosted Responses bodies omit the key and all affinity headers.
- The chatgpt.com body key and `x-client-request-id` always agree, and no
  session header is invented when the session id is absent.
- The key is always `pck_`-prefixed and at most 64 characters.
- Live cached-token evidence is recorded only when an authorized isolated
  route exists; otherwise the gate stays explicitly blocked.

## Definition of Done

- Focused adapter tests cover the behavior and its failure boundaries.
- Analyzer and the required test scope pass.
- The owning adapter contract and active design documentation are current.
- The QA page records the fixture matrix and the live-gate status.
- A Draft PR exists with the correct labels and green exact-head CI.
- No credential, private Home, occupied Test Home, or runtime switch is used.

## Verification commands

```bash
cd agent
set -o pipefail; fvm dart analyze 2>&1 | tail -5
set -o pipefail; fvm dart test test/engine/adapters test/guards/file_size_ratchet_guard_test.dart --reporter expanded 2>&1 | tail -5
cd ..
git diff --check
graphify update .
```

## Remaining work

1. Obtain or explicitly record the live cached-token gate result without
   crossing the credential/Home/runtime boundary.
2. Update this plan and the PR body with that evidence.
3. Keep the PR in Draft until the owner explicitly authorizes the next step.
