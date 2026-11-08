---
title: "Codex Prompt-Cache Affinity QA"
description: "Fixture coverage and owner-accepted live retention evidence for Codex Responses prompt_cache_key routing, GitHub exclusions, xAI raw-body support, and chatgpt.com affinity headers."
---

# Codex Prompt-Cache Affinity QA

## Scope

Validates Task 145: the Codex Responses request carries a stable
content-addressed `prompt_cache_key` across a conversation, the endpoint policy
drops it only for GitHub-hosted Responses endpoints, and the chatgpt.com Codex
backend receives matching affinity headers in sync and stream.

Design and wire contract:
[Codex Responses Runtime Design](../agent_engine/codex_responses_runtime_design.md)
and [Engine Adapters Contract](../../agent/lib/engine/adapters/AGENTS.md).

The fixture matrix observes the actual adapter HTTP body and headers through a
mock carrier, so it is not live vendor acceptance. Live retention evidence is
separate and is recorded as an owner-accepted usage sample below.

## Fixture Matrix

| Area | Scenario | Expected | Suite |
|---|---|---|---|
| Policy | `api.x.ai`, `chatgpt.com`, `api.openai.com`, unrelated and lookalike domains | Supported | `agent/test/engine/adapters/codex_responses_adapter_test.dart` |
| Policy | `api.github.com`, `github.ai`, `models.github.ai`, `githubcopilot.com`, `api.githubcopilot.com` | Unsupported; exact or dot-suffix only | same |
| Sync/stream | Same history and tools on chatgpt.com | Identical `prompt_cache_key`, `session_id`, and `x-client-request-id`; `stream: true` on both | same |
| xAI | `https://api.x.ai/v1` | Body keeps `prompt_cache_key`; no `session_id` or `x-client-request-id` | same |
| GitHub | `api.github.com`, `models.github.ai`, `api.githubcopilot.com` | Body omits `prompt_cache_key`; no affinity headers | same |
| OpenAI | `https://api.openai.com/v1` | Body keeps `prompt_cache_key`; no affinity headers | same |
| History | Appending assistant/user turns in sync and stream | Key unchanged | same |
| Content | Instructions, tool set, tool schema, or tool name changes | Key rotates | same |
| Ordering | Tool list order and schema map insertion order | Key unchanged | same |
| Scope | Different session ids, including absent | Different keys | same |
| Bounds | Null, blank, 500-character, and 20,000-character inputs | Null when empty; `pck_<24 hex>` at most 64 characters when bounded | same |
| Headers | chatgpt.com with no session id | No invented `session_id`; `x-client-request-id` still mirrors the body key | same |

Focused command:

```bash
cd agent
fvm dart test test/engine/adapters/codex_responses_adapter_test.dart --reporter expanded
```

## Live Cached-Token Gate

Status: **closed on 2026-11-08 with owner-accepted live evidence.** The
evidence below is OWNER-REPORTED / OWNER-ACCEPTED; this task did not rerun the
live probe. No credential, primary Home, occupied Test Home, or runtime switch
was used by this task, and no request, session, model, or commit metadata was
captured for tracked notes.

### Accepted sample

Before the change, `(input_tokens, cached_tokens)` per request:

| Request | `input_tokens` | `cached_tokens` |
|---|---|---|
| 1 | 8878 | 0 |
| 2 | 15125 | 0 |
| 3 | 39586 | 0 |
| 4 | 60807 | 0 |
| 5 | 86673 | 0 |
| 6 | 104199 | 8832 |
| 7 | 117941 | 0 |
| 8 | 126175 | 117760 |
| 9 | 136953 | 39808 |

After the change, consecutive requests `(input_tokens, cached_tokens)`:

| Request | `input_tokens` | `cached_tokens` |
|---|---|---|
| 1 | 12052 | 0 |
| 2 | 26078 | 12288 |
| 3 | 44708 | 25984 |
| 4 | 56851 | 44544 |
| 5 | 63739 | 56704 |

### Observations

- The before sample alternates between zero and large cached counts
  (`0, 0, 0, 0, 0, 8832, 0, 117760, 39808`), the warm/cold flapping this task
  targets.
- In the after sample the first request is cold (`12052, 0`) and the four
  subsequent requests retain approximately the previous request's full input
  prefix: `12288` against `12052`, `25984` against `26078`, `44544` against
  `44708`, and `56704` against `56851`. No warm zero-cache drop appears in this
  sample.
- Retention is approximate, not exact: `12288` exceeds the previous request's
  `12052` input tokens. Counts are recorded as reported, with no clamping or
  normalization. The owner's approximate 128-token bucket explanation is not
  an independently verified provider invariant.
- This sample does not claim universal 100% retention; it records one accepted
  consecutive-request sample on the Codex route.

### Criteria separation

Routing correctness and measured cache retention remain separate criteria:

- Routing correctness is proven by the fixture matrix above: the body and
  header shape of each supported and excluded host.
- Measured retention is proven only by live usage counts such as this sample.
  A justified cold response alone does not prove improved retention, and a
  changed routing key does not guarantee a cold read.

### Re-running later

Prerequisites for a fresh probe:

- A prepared worktree-scoped Test Home with an authenticated `openai-codex`
  provider instance, or an owner-designated Test Home with the same.
- Explicit authorization to use that Test Home for live Codex requests.
- Request dumps enabled for the test session so `input_tokens_details.cached_tokens`
  can be read without capturing credentials or conversation content in tracked
  notes.

Procedure:

1. Start the Agent against the authorized Test Home and select the
   `openai-codex` route with a model that reports prompt-cache usage.
2. Send two turns in one session where the second turn strictly extends the
   first: the system instructions and tool set stay unchanged.
3. Read both request dumps and confirm the request body carries the same
   `pck_` key and that the chatgpt.com request carries `session_id` plus a
   matching `x-client-request-id`.
4. Read the second response usage and record only the numeric
   `cached_tokens` value plus the request correlation id.
5. Optionally repeat with a changed tool set and confirm the key rotates and
   the second turn is a cold read.

Pass criteria:

- The key is present, stable across the strict prefix extension, and at most
  64 characters.
- The affinity headers agree with the body key.
- The second turn reports `cached_tokens > 0` when the provider retains the
  prefix, or the provider explicitly reports a cold read with a documented
  reason.
- No credential or message content appears in tracked evidence.

Current evidence: the fixture matrix passes and the live retention gate is
closed by the owner-accepted sample above. The live sample was not independently
rerun by this task.
