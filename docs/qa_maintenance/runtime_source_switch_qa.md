---
title: "Runtime Source Switch QA"
description: "Regression matrix for moving one active sanad-dev pair between source worktrees without changing its durable runtime identity."
---

# Runtime Source Switch QA

## Core scenarios

| Scenario | Expected result |
|---|---|
| Agent considers switching without a direct user instruction | It does not invoke the command and leaves every runtime unchanged. |
| User asks to implement, test, debug, verify, restart, or deploy the feature | The request is not treated as switch authorization. |
| Another session may share the selected pair | The agent warns that all shared sessions will reconnect and waits for fresh user confirmation. |
| Requester identity is available but user consent is absent | Identity may select a pair but must not authorize execution. |
| User directly confirms the identified runtime and target worktree | The agent may invoke the command once; failure or rollback requires a new direct instruction before retry. |
| Authorized switch targets an unprepared worktree | The same switch command idempotently prepares Contract, Agent, and Client packages before submitting the handoff; no separate setup command is required. |
| Target preparation fails | The command fails before writing the handoff transaction, and the source runtime remains unchanged. |
| Agent requests `switch --runtime current` from a target worktree after authorization | Only the requester pair drains and restarts from the target source. |
| Authorized source handoff begins | The agent runs `status` from the source worktree first and records the selected source, branch, agent, and clients. |
| Agent-origin target startup succeeds | The original switch tool call returns `complete`; the agent then runs `status` from the target worktree and verifies its source, branch, agent, and clients. |
| Startup loads history while the switch shell tool owns a valid deferred result | History healing and checkpoint trim preserve the complete assistant tool-call batch; resume resolves the launcher manifest into the original tool result before another model request, and no duplicate `switch` command or transient missing-client error is produced. |
| Previous Client termination is delayed while the retained VM port still answers | Target startup waits; the previous source cannot satisfy readiness and the handoff cannot become `complete`. |
| Previous and target Client identities overlap briefly on one retained VM port | Lease PID collection accepts exactly the target workspace source marker plus launcher id/nonce and rejects the stale previous identity. |
| Agent-origin target startup fails and rollback succeeds | The original switch tool call returns `rolled_back` after the same durable session resumes on the previous source; target-scoped status remains diagnostic and cannot override that result. |
| Target and rollback both fail | The original switch tool call returns `recovery_failed` and does not claim continuity. |
| Safe drain or pre-replacement validation fails | The original switch tool call returns `failed` and the source group remains intact. |
| Two or more runtimes are active | Requester port selects one runtime group; all other PIDs, ports, Homes, and sessions remain unchanged. |
| One agent has macOS and iPhone Simulator clients | Status lists both clients; switch preserves both device ids and VM-service ports and completes only after both are healthy. |
| One target client fails startup | The target group is terminated and the agent plus every previous client are restored. |
| Status is invoked from a different worktree with an explicit agent port | Output distinguishes the command worktree/branch from the selected runtime source/branch. |
| Target Client paths match the invoking worktree but the Agent workspace hash does not, or vice versa | Switch reports inconsistent Agent/Client sources and fails closed; it does not claim the runtime already uses the target. |
| Agent workspace hash and every managed Client source match the target | Switch may report that the runtime already uses the target without submitting another handoff. |
| Human command is ambiguous | Command fails and requests `--port`; no manifest or process mutation occurs. |
| Target worktree already runs a pair | Command fails before drain; neither runtime changes. |
| Target agent and client become healthy | Retained Home, gateway port, VM-service port, cloud mode, preferences namespace, and session recovery are unchanged. |
| Client reconnects with an identity-only selected-session placeholder | The persisted provider/model route remains sendable until complete authoritative session context arrives. |
| A confirmed route revision repeats after one local route field is lost | The repeated authoritative snapshot repairs the missing field without overwriting non-empty pending local intent. |
| Target agent fails startup | Previous agent and client source roots are restored. |
| Target client fails startup | Target agent is stopped and the complete previous pair is restored. |
| Safe restart is rejected or times out | Existing pair remains running and the handoff record reports failure. |
| Switch to the primary checkout | Linked-worktree client markers are removed while retained runtime state stays unchanged. |
| Packaged service, manual IDE pair, stale lease, or incomplete profile is selected | Command fails closed; no process is terminated. |
| One unchanged invalid or unsupported-version handoff manifest remains on disk | Launcher remains fail-closed and emits at most one warning for that file revision rather than once per poll. |
| The invalid handoff manifest is replaced, then later becomes valid or disappears | The replacement may emit one new warning; a successful/absent read resets warning suppression. |

## Automated coverage

Focused unit coverage owns manifest serialization and validation, retained
Flutter compile arguments, worktree-marker replacement/removal, and terminal
handoff status. Process-level coverage must use unique ports and a temporary
Sanad Home, run sequentially, assert requester recovery after the Terminal tool
result, and verify rollback without touching any other discovered runtime.
