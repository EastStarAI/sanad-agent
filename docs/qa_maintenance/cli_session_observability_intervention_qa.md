---
title: "CLI Session Observability & Safe Intervention QA Matrix"
description: "QA validation matrix for daemon-backed CLI session observability, authoritative inspection, explicit question answering, ordinary tool permission decisions, cross-session safety, and scoped session termination."
---

# CLI Session Observability & Safe Intervention QA Matrix

## 1. Observability & State Inspection (`session list`, `session show`)

| Scenario | CLI Command | Expected Output / State | Exit Code |
|---|---|---|---|
| List sessions with pending intervention | `sanad session list` | Formatted active sessions list displaying `[Pending intervention]` tag alongside session ID, title, and model. | 0 |
| List sessions in JSON mode | `sanad session list --json` | Valid JSON array of session objects containing `session_id`, `title`, `model`, and metadata with `has_pending_permission_request`. | 0 |
| Show session pending clarification | `sanad session show <session-id>` | Authoritative status `needs_input`, displays question prompt, options (if present), request ID, and the exact intervention command syntax. | 0 |
| Show session pending tool permission | `sanad session show <session-id>` | Authoritative status `needs_permission`, displays tool name, formatted tool input arguments, request ID, and the permission decision command syntax. | 0 |
| Show session running | `sanad session show <session-id>` | Authoritative status `running`, displays `in_flight` execution snapshot including `type` and `run_id`. | 0 |
| Show session idle | `sanad session show <session-id>` | Authoritative status `idle`, zero pending intervention requests, displays message count and session metadata. | 0 |
| Show session in JSON mode | `sanad session show <session-id> --json` | Single JSON envelope containing `session_id`, `status` (`needs_input` / `needs_permission` / `running` / `idle`), owner `identities`, `in_flight`, `pending_permission_request`, effective route (`model`, `provider_instance_id`, `route_revision`, `thinking_mode`), timestamps, `message_count`, and a bounded `summary` of user/reply/tool/reasoning counts. The full `messages` payload is **omitted** by default. | 0 |
| Show session in JSON mode with full history opt-in | `sanad session show <session-id> --json --include-messages` | Same bounded envelope plus the complete `messages` (full conversation/history) payload embedded explicitly. | 0 |
| Show session missing argument | `sanad session show` | Error message `Error: Session ID is required.` and usage instructions. | 1 |

---

## 2. Safe Intervention Resolution (`session answer`, `session permission`)

| Scenario | CLI Command | Daemon Gateway Behavior | Exit Code |
|---|---|---|---|
| Submit direct answer to clarification question | `sanad session answer <session-id> -r <req-id> --answer "Text"` | Correlates to pending `system_ask_user` request, claims checkpoint, unblocks model turn, returns `outcome: resolved`. | 0 |
| Submit answer via file containing raw text | `sanad session answer <session-id> -r <req-id> --file answer.txt` | Reads trimmed file content, submits answer, returns `outcome: resolved`. | 0 |
| Submit answer via file containing JSON | `sanad session answer <session-id> -r <req-id> --file answer.json` | Extracts `answer` or `text` key from JSON object, submits answer, returns `outcome: resolved`. | 0 |
| Submit allow decision for gated tool | `sanad session permission <session-id> -r <req-id> --allow` | Dispatches `allowed: true, decision: allow` to daemon, claims checkpoint, executes tool, returns `outcome: resolved`. | 0 |
| Submit deny decision for gated tool with comment and scope | `sanad session permission <session-id> -r <req-id> --deny --scope session --comment "Disallowed"` | Dispatches `allowed: false, decision: deny`, scope `session`, and comment, cancels tool invocation, returns `outcome: resolved`. | 0 |
| Submit permission via JSON file payload | `sanad session permission <session-id> -r <req-id> --file decision.json` | Reads `allowed`, `decision`, `scope`, `comment` keys, dispatches payload, returns `outcome: resolved`. | 0 |

---

## 3. Strict Identity & Kind Validation (Fail-Closed Safety)

| Scenario | Input | Error Code | Outcome / Guard Behavior |
|---|---|---|---|
| Cross-session intervention attempt | Response sent with `session_id` differing from the checkpoint's owning session. | `CROSS_SESSION_MISMATCH` | `cross_session_mismatch`; request is NOT consumed or claimed; turn remains pending on the legitimate session. |
| Submit answer to ordinary tool permission | Calling `session answer` (or passing `answer`) for a tool like `run_terminal_command`. | `INVALID_INTERVENTION_KIND` | `wrong_kind`; rejected without claiming checkpoint. |
| Submit tool permission to clarification question | Calling `session permission` (without `answer`) for `system_ask_user`. | `INVALID_INTERVENTION_KIND` / `INVALID_ANSWER` | `wrong_kind`; rejected without claiming checkpoint. |
| Empty / whitespace answer | Calling `session answer` with empty or whitespace-only text. | `INVALID_ANSWER` / `EMPTY_CLARIFICATION_ANSWER` | Rejected locally or by gateway; checkpoint remains awaiting valid answer. |
| Contradictory decision fields | Payload contains conflicting fields (e.g. `allowed: true, decision: deny`). | `CONTRADICTORY_DECISION` | `invalid_decision`; rejected without consuming request. |
| Non-boolean allowed field | Payload contains string or number for `allowed` (e.g. `"allowed": "yes"`). | `MALFORMED_DECISION` | `invalid_decision`; rejected without consuming request. |

---

## 4. Non-Interactive One-Shot Execution Policy (`sanad run`)

| Scenario | Options | Expected Runtime Behavior |
|---|---|---|
| Gated tool encountered in headless run without flags | `sanad run "<prompt>"` | Emits notice to stderr (`Notice: Gated tool "..." requires permission for session ... Intervene via: sanad session permission ...`), leaves permission pending for external intervention, does NOT auto-deny. |
| Gated tool encountered with `--allow-all-tools` | `sanad run "<prompt>" --allow-all-tools` | Auto-approves ordinary tool execution; model turn continues without intervention. |
| Clarification question (`system_ask_user`) encountered with `--allow-all-tools` | `sanad run "<prompt>" --allow-all-tools` | Notice emitted to stderr; question remains pending and is NOT auto-approved; `--allow-all-tools` applies only to ordinary tool permissions. |

---

## 5. Scoped Session Termination (`session stop`)

| Scenario | CLI Command | Expected Runtime Behavior | Exit Code |
|---|---|---|---|
| Stop specific session | `sanad session stop <session-id>` | Daemon emits `stop` GatewayEvent targeting `<session-id>` specifically. Ongoing turn halts. Other active sessions remain unaffected. | 0 |
| Stop session in JSON mode | `sanad session stop <session-id> --json` | Outputs `{"session_id": "<id>", "status": "stopped"}`. | 0 |
| Stop session missing argument | `sanad session stop` | Error message `Error: Session ID is required.` and usage instructions. | 1 |

---

## 6. Concurrency & Idempotency (First-Writer-Wins)

| Scenario | Initial State | Concurrency Trigger | Expected Result |
|---|---|---|---|
| Racing duplicate intervention responses | Checkpoint in status `awaiting_permission` | Two responses arrive concurrently for the same `request_id` | Exactly one writer wins the database claim (`claimSuspendedCheckpointDecision`); winning response resumes execution (`outcome: resolved`). Losing writer receives `ALREADY_RESOLVED` and does NOT resume a second turn. |
| Stale intervention after resolution | Checkpoint already resolved | A late intervention arrives for `request_id` | Gateway returns `outcome: already_resolved`, errorCode `ALREADY_RESOLVED`. |
| Duplicate intervention across mismatched session | Checkpoint already resolved for session A | A duplicate arrives targeting session B | Gateway returns `outcome: cross_session_mismatch`, errorCode `CROSS_SESSION_MISMATCH` (cross-session validation takes precedence). |
