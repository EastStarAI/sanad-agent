---
title: "Codex Prompt-Cache Affinity QA"
description: "Fixture and live-gate coverage for Codex Responses prompt_cache_key routing, GitHub exclusions, xAI raw-body support, and chatgpt.com affinity headers."
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

All fixture evidence below observes the actual adapter HTTP body and headers
through a mock carrier. It is not live vendor acceptance.

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

Status: **blocked pending an owner-authorized isolated authenticated Codex
route.** No credential, primary Home, occupied Test Home, or runtime switch is
used by this task.

Prerequisites:

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

Current evidence: the fixture matrix passes; the live gate has not run because
no authorized isolated authenticated route was available. This gap is recorded,
not inferred as a pass.
