---
title: "CLI Session Observability & Safe Intervention QA Matrix"
description: "QA validation matrix for daemon-backed CLI session observability, authoritative inspection, non-interactive live steering, runtime recovery retry, explicit question answering, ordinary tool permission decisions, cross-session safety, and scoped session termination."
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
| Show session executing a tool with no partial stream | `sanad session show <session-id>` | Authoritative status `running` from the durable `execution_state`, even though `in_flight` is absent: a tool executes without publishing a partial stream. Never `idle`. | 0 |
| Show a session the daemon is retrying | `sanad session show <session-id> --json` | Status `retrying`; `execution_state` is `waiting`, `runtime_notice` carries `status`, `reason`, `retry_attempt`, `retry_budget`, and `retry` reports `pending: true` with `label: "retrying (1/1)"`. Text mode prints `Status: retrying`, `Execution: waiting`, and `Recovery: retrying (1/1) (timeout) in 2s — the daemon continues this turn automatically`. | 0 |
| Show a truly stopped session | `sanad session show <session-id> --json` | Status `blocked`; `retry` reports `pending: false`, `stopped: true`, `label: "needs_intervention"` — a non-retryable reason, an exhausted budget, or a cancelled resume. | 0 |
| Show an unknown session id | `sanad session show does-not-exist` | `Error: Session does-not-exist was not found. Check the id with: sanad session list`; `--json` prints `{"session_id": "does-not-exist", "exit_code": 1, "error_code": "session_not_found"}`. Never `idle`. | 1 |
| Show session idle | `sanad session show <session-id>` | Authoritative status `idle`, zero pending intervention requests, displays message count and session metadata. | 0 |
| Show session in JSON mode | `sanad session show <session-id> --json` | Single JSON envelope containing `session_id`, `status` (`needs_input` / `needs_permission` / `running` / `resuming` / `retrying` / `blocked` / `stopping` / `idle`), `execution_state`, `runtime_notice`, `retry`, owner `identities`, `in_flight`, `pending_permission_request`, effective route (`model`, `provider_instance_id`, `route_revision`, `thinking_mode`), timestamps, `message_count`, and a bounded `summary` of user/reply/tool/reasoning counts. The full `messages` payload is **omitted** by default. | 0 |
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
| Turn refused before it starts | `sanad run "<prompt>" --workspace <gone-workspace>` | Exit `1` at once with one line, `Error: turn_failed: <cause>.` — no repeated `Error:` prefix and no doubled period. |
| Turn blocked by the daemon | `sanad run "<prompt>" --timeout 120` against a route that blocks | Exit `1` at once with one line, `Error: blocked: <reason>. Intervene with sanad session stop <id> or retry from a client.` (a single period before `Intervene`), and no Stop is sent. |
| Turn retried automatically after a retryable failure | `sanad run "<prompt>"` where the provider times out while the reason still has retry budget | The run keeps following: stderr carries `Notice: retrying (1/1) — …`, the result artifact records `status: retrying`, and no `Error: blocked` line is printed. The turn ends with the retried attempt's own outcome. |
| Turn blocked after the retry budget is spent | `sanad run "<prompt>"` where the retryable failure exhausts its budget | Exit `1` with `Error: blocked: <reason>. …` exactly as a non-retryable block, and the daemon schedules no further attempt. |

---

## 5. Scoped Session Termination (`session stop`)

| Scenario | CLI Command | Expected Runtime Behavior | Exit Code |
|---|---|---|---|
| Stop specific session | `sanad session stop <session-id>` | The CLI dispatches one session-scoped `stop` (naming the in-flight `run_id` it resolved from `session show` state, if any) and then confirms authoritative idle state. The daemon halts the turn, releases the in-flight projection and any interactive-wait checkpoints, and other active sessions remain unaffected. | 0 |
| Stop session in JSON mode | `sanad session stop <session-id> --json` | Outputs `{"session_id": "<id>", "status": "stopped"}` only after the idle confirmation. | 0 |
| Stop an unresponsive turn | `sanad session stop <session-id>` | The command keeps re-reading session state until the client request timeout (default 15 s) and then fails with `stop_timeout` and exit 1; it never prints `stopped` for a session that is still running. | 1 |
| Stop session missing argument | `sanad session stop` | Error message `Error: Session ID is required.` and usage instructions. | 1 |
| Post-stop state | `sanad session show <session-id> --json` | `status` is `idle`, `in_flight` is `null`, and `pending_permission_request` is `null`; a frozen `in_flight` snapshot (`type: thought_stream`, frozen `updated_at`) after a stop is a defect. | 0 |

---

## 6. Manual Session Compaction (`session compact`)

| Scenario | CLI Command | Expected Runtime Behavior | Exit Code |
|---|---|---|---|
| Request compaction for session | `sanad session compact <session-id>` | Daemon receives the correlated `session.compact` query and replies after compaction finishes (`SessionRunOrchestrator.handleCompactCommand` awaits `runCompaction`); the CLI prints `Compaction request accepted for session <session-id>` for a completed compaction. Single dispatch, no retry on timeout. | 0 |
| Request compaction in JSON mode | `sanad session compact <session-id> --json` | Outputs JSON object containing `session_id`, `outcome` (`accepted` / `dispatched` / `no_op` / `failed`), and correlated IDs (`compaction_id`, `request_id`). | 0 |
| Compaction request rejected or busy | `sanad session compact <session-id> --json` | Returns JSON object with failure outcome (`failed`, `session_busy`, `compaction_in_progress`), `failure_reason`, and `exit_code: 1`. | 1 |
| Slow compaction (Task 125) | `sanad session compact <session-id> --json` | Waits past the former 5 s bound for the real terminal result, up to the Home's `compaction.passTimeoutSeconds` (default 600 s) unless `--timeout` overrides it; returns `outcome: accepted` with one dispatch. Covered by `agent/e2e_test/session_queue_release_e2e_test.dart` G2.3. | 0 |
| Wait bound exhausted | `sanad session compact <session-id> --json` | No resend; returns `outcome: unconfirmed`, `poll: sanad session show <session-id>`, `exit_code: 124`. Not a failure: the daemon may still be compacting, and `session show` reports the latest `compaction` status. | 124 |
| Connection failure | `sanad session compact <session-id> --json` | Fails closed after the single dispatch attempt; returns JSON error with `exit_code: 1`. | 1 |
| Missing or malformed daemon response | `sanad session compact <session-id> --json` | Rejects malformed payload; returns `outcome: failed`, `failure_reason: missing_outcome`, and `exit_code: 1`. | 1 |
| REPL `/compact` slow or timed out (Task 119) | `/compact` inside `sanad` REPL | Exactly one `session.compact` dispatch, never resent. A timeout renders the neutral notice `Compaction may still be running…`, never an error, `dispatched` or success; `accepted` renders as completed, and busy or failure outcomes render with their reason. Covered by `agent/test/cli/slash_command_handler_test.dart` group `/compact outcomes (Task 119)`. | 0 |
| Compact session missing argument | `sanad session compact` | Error message `Error: Session ID is required.` and usage instructions. | 1 |

---

## 7. Non-Interactive Live Steering (`session steer`)

Contract owner: Section 9.5 of `docs/technical/sanad_cli_architecture.md`. A successful
`session steer` proves the gateway acknowledged the text as a **pending steer** for the
active turn; it never proves the instruction was applied, which happens at the next
execution boundary. Every dispatch carries `steer_only: true`, so the daemon itself
refuses a steer that has no live owner instead of turning it into a turn.

| Scenario | CLI Command | Expected Runtime Behavior | Exit Code |
|---|---|---|---|
| Steer the active turn | `sanad session steer <session-id> --message "Add an audit trail"` | One `steer` dispatch; the daemon registers a pending steer for the owning run and publishes `session.pending_steer_changed` / `session.message_classified` with `classification: steer`. Plain output is `Steer sent to session <id> (request <reqId>).` | 0 |
| Steer in JSON mode | `sanad session steer <session-id> --message "Add an audit trail" --json` | Outputs `{"session_id": "<id>", "request_id": "<req-id>", "status": "steer_sent"}` only after the gateway acknowledgement. | 0 |
| Steer text from a file | `sanad session steer <session-id> --message-file steer.txt` | Reads the file as plain text, trims it, and dispatches the trimmed body. The path itself is used verbatim, never trimmed. | 0 |
| No active turn (pre-check) | `sanad session steer <idle-session-id> --message "Add scope"` | Refused **before** dispatch with `error_code: no_active_turn`; nothing is dispatched, queued, or created. The daemon would also reject the same steer through `steer_only`, so the outcome does not depend on this read. | 3 |
| No active turn (daemon guard) | a steer that races the turn's completion, so the pre-check passed and the run ended before admission | The daemon rejects it with one correlated `error` frame, `code: no_active_turn`; the text is **not** queued and **no** turn is started (the run's own turn is the only turn). | 3 |
| Stale `in_flight` projection | `sanad session steer <stopped-session-id> --message "Add scope"` | A leftover in-memory partial-stream snapshot whose durable execution snapshot is not `running`/`resuming` is not read as an active turn; the command reports `no_active_turn` and dispatches nothing. | 3 |
| Stop requested or draining | `sanad session steer <stopping-session-id> --message "Add scope"` | The durable `stopping` state (written before the run is cancelled) or an active runtime notice outside `resuming` is not steerable; nothing is dispatched. The projection carries no in-memory stop flag, so a stop that has not yet written `stopping` is refused by the daemon's own `steer_only` guard instead. | 3 |
| Older daemon admitted a new turn | `sanad session steer <id> --message "..."` against a daemon that ignores `steer_only` | The daemon classifies the message `think`; the CLI reports `admitted_as_turn` and states that **a turn is now running**, never that the steer was applied. | 6 |
| Older daemon queued the text | the same, while the session is busy with older work | The daemon classifies the message `queue`; the CLI reports `queued_as_turn` and states that **a turn is now queued**. | 7 |
| Typed gateway rejection | `sanad session steer <id> --message "..." --json` | A matching `error` frame is reported with the gateway's own `error_code` and exit `4`. | 4 |
| Dispatched but unacknowledged | `sanad session steer <id> --message "..." --timeout 5` | No acknowledgement within the bound (default 15 s) reports `steer_unacknowledged`, prints the request id, and advises `sanad session show <id>`; it is never reported as sent. | 5 |
| Invalid invocation | `sanad session steer <id>` with neither message source, both sources (even when one is blank), an empty message, an unusable `--timeout` (0, negative, non-numeric, above 86400), or a missing/directory/unreadable/empty `--message-file` | `Error:` line plus usage on stderr, `error_code: invalid_arguments` in `--json` mode, and no dispatch. | 2 |
| Session state unreadable | `sanad session steer <id> --message "..."` where the projection read returns a typed error | `session_state_unreadable` (exit `8`): the reason is reported as "could not read session state", distinct from any steer verdict, because no steer was sent. | 8 |
| Daemon unreachable | `sanad session steer <id> --message "..."` with no daemon listening | Fails closed without dispatching the steer and reports the transport code (`connection_failed`/`disposed`/`not_connected`), never "Gateway rejected". | 1 |
| Message body confidentiality | any failed steer | The steer body never appears on stdout, stderr, or in logs; only identities, codes, and lifecycle metadata are reported. | — |

Automated coverage: `agent/test/cli/session_command_test.dart` (group `session steer`),
`agent/test/cli/steer_acknowledgement_test.dart` (the real acknowledgement
classification over a scripted socket), and
`agent/test/interfaces/runtime/steer_only_admission_test.dart` (the daemon's
`steer_only` rejection and the unchanged legacy admit-or-queue path), all daemon-free.

For the two race rows ("No active turn (daemon guard)" and "Older daemon admitted a new
turn") the observable outcome is not "nothing happens": the text is refused in the first
case and becomes a turn in the second. Only the first is guaranteed to create nothing,
because the daemon honours `steer_only`.

### 7.1. Known Edge: A Steer That Outlives the Turn

A steer delivered at the turn's final tool boundary, after which the run reaches no
execution boundary to drain it, is neither applied nor reported to the already-finished
command: `sanad session steer` exited `0` because its claim is acknowledgement as a
pending steer, not application. On the next daemon restart the unresolved pending record
becomes a durable **recovered draft** rather than a steer into the new generation, so the
text reappears in the session history instead of being silently dropped.

| Step | Command | Expected Observation |
|---|---|---|
| Steer at the final tool boundary | `sanad session steer <id> --message "Add scope"` while the turn's last tool result is being committed | Exit `0` with `steer_sent`; the text may never be applied. |
| Evidence of non-application | `sanad session show <id> --json` | No assistant output contains the steer text; the pending-steer record is not `delivered`. |
| Recovered draft after restart | restart the Agent, then `sanad session show <id> --json` | The unresolved text is present as recovered draft content, and no new turn was started by the steer. |

This is a documented limitation, not a success path: a caller that must know whether the
text took effect reads the history or the pending-steer lifecycle, never the exit code.

---

## 8. Runtime Recovery Retry (`session retry`)

Contract owner: Section 9.6 of `docs/technical/sanad_cli_architecture.md`. A successful
`session retry` proves the daemon's recovery projection moved the session to `resuming`; it
never proves the resumed provider request succeeded. The command sends the same
`session.runtime_retry` command the Sanad Client's Retry action sends, after proving the
session is actually in a retryable recovery state.

| Scenario | CLI Command | Expected Runtime Behavior | Exit Code |
|---|---|---|---|
| Retry a blocked session | `sanad session retry <blocked-session-id>` | One `session.runtime_retry` dispatch; the daemon claims the suspended request, publishes `session.runtime_notice` with `status: resuming` and reason `manual_retry`, and the CLI prints `Retry accepted for session <id> (request <reqId>)`. | 0 |
| Retry in JSON mode | `sanad session retry <id> --json` | Outputs `{"session_id": "<id>", "request_id": "<req-id>", "status": "retrying", "notice_request_id": "<turn-req-id>"}` only after the `resuming` transition. | 0 |
| Retry a waiting session | `sanad session retry <waiting-session-id>` | A `waiting` notice is retryable: the manual retry shortens the remaining cooldown and the daemon resumes immediately. | 0 |
| Retry a session the daemon is already retrying | `sanad session retry <retrying-session-id>` | Accepted like `waiting`: the manual retry shortens the scheduled attempt instead of starting a second turn. | 0 |
| Retry on another route | `sanad session retry <id> --provider <instance-id> --model <model-id>` | The payload carries `provider_instance_id`/`model_id`; the same suspended request resumes on that route with reason `manual_retry`. This is not the Change Provider action: that is `session.runtime_continue_with_provider` with reason `provider_changed`. | 0 |
| Not blocked or waiting | `sanad session retry <idle-or-running-session-id>` | Refused **before** dispatch with `error_code: not_blocked`; nothing is sent, so a healthy session never gains a second turn. | 3 |
| Typed rejection | `sanad session retry <id> --json` where the daemon answers with a correlated blocked notice (unsafe checkpoint, provider with no default model) | Reported with the gateway's own code, for example `retry_rejected` or `model_not_found`, and the notice title/message are quoted. | 4 |
| Dispatched but unacknowledged | `sanad session retry <id> --timeout 5` while the session is busy with another resume | No correlated and no session `resuming` transition within the bound reports `retry_unacknowledged` with the request id and advises `sanad session show <id>`; it is never reported as accepted. | 5 |
| Invalid invocation | `sanad session retry` with no session id, or `--timeout 0`/negative/non-numeric/above 86400 | `Error:` line plus usage on stderr, `error_code: invalid_arguments` in `--json` mode, and no dispatch. | 2 |
| Session state unreadable | `sanad session retry <id>` where the projection read returns a typed error | `session_state_unreadable` (exit `8`): nothing was sent, so this is not a rejection. | 8 |
| Daemon unreachable | `sanad session retry <id>` with no daemon listening | Fails closed without dispatching and reports the transport code, never "Gateway rejected". | 1 |
| Exhausted automatic retry | a `provider_timeout` worker that already used its one automatic attempt | The blocked notice states `Automatic retry gave up after 1 attempt; retry manually or choose another provider.`; nothing resumes until this command (or the Client's Retry) is used. | — |
| Streaming prevented a retry | a `provider_timeout` after output started streaming | The blocked notice states `No automatic retry: the response had already started streaming.` | — |

Automated coverage: `agent/test/cli/session_command_test.dart` (group `session retry`),
`agent/test/cli/retry_acknowledgement_test.dart` (payload shape, acceptance, rejection and
timeout over a scripted socket), and
`agent/test/engine/runtime/runner_recovery_coordinator_test.dart` (the exhausted-budget
note), all daemon-free.

---

## 9. Concurrency & Idempotency (First-Writer-Wins)

| Scenario | Initial State | Concurrency Trigger | Expected Result |
|---|---|---|---|
| Racing duplicate intervention responses | Checkpoint in status `awaiting_permission` | Two responses arrive concurrently for the same `request_id` | Exactly one writer wins the database claim (`claimSuspendedCheckpointDecision`); winning response resumes execution (`outcome: resolved`). Losing writer receives `ALREADY_RESOLVED` and does NOT resume a second turn. |
| Stale intervention after resolution | Checkpoint already resolved | A late intervention arrives for `request_id` | Gateway returns `outcome: already_resolved`, errorCode `ALREADY_RESOLVED`. |
| Duplicate intervention across mismatched session | Checkpoint already resolved for session A | A duplicate arrives targeting session B | Gateway returns `outcome: cross_session_mismatch`, errorCode `CROSS_SESSION_MISMATCH` (cross-session validation takes precedence). |

---

## 10. Automated One-Shot Intervention Readiness (In-Process Coverage)

`agent/test/cli/run_delegation_test.dart` locks the Section 4 policy without a daemon. Turn events are emitted only after the run dispatched the turn (`await client.turnDispatched.future`), because the initial `running` artifact is recorded before the runner subscribes to the client's event streams. The readiness contract is owned by Section 8.1 of `docs/technical/sanad_cli_architecture.md`.

| Scenario | Automated Coverage | Readiness Gate |
|---|---|---|
| Clarification question surfaces as `needs_input` without terminating the run, resumption returns to `running`, and a gated tool stays `needs_permission` (fail-closed, no auto-answer) before completing | `surfaces non-terminal needs_input and needs_permission events without terminating run` | Turn dispatch readiness |
| `--allow-all-tools` auto-approves ordinary tool permissions only; `system_ask_user` remains pending | `--allow-all-tools auto-approves ordinary tool permissions but leaves system_ask_user pending` | Turn dispatch readiness |
| The `running` artifact is observable while the run has no turn-event subscriber, and an intervention emitted after dispatch readiness is always observed | `turn event readiness is the dispatch signal, not the initial running artifact` | Unbounded (held) pre-dispatch window |
| Terminal classification precedence: timeout (124), SIGINT (130), external cancellation (130) and incomplete `missing_final` (1) are not overwritten by late events | sibling `run_delegation_test.dart` cases | Post-dispatch and post-terminal emission |
