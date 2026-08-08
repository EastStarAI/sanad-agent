---
title: "sanad-dev Switch Recovery and Client Identity Race"
description: "Prevent duplicate source-switch execution and stale Client lease identity during continuous handoff."
status: "completed"
---

# sanad-dev Switch Recovery and Client Identity Race

## Goal

Make an authorized `sanad-dev switch --runtime current` complete exactly once,
return the original launcher transaction result after daemon recovery, and mark
the handoff complete only after every replacement Client has a target-source
managed identity recorded in the launcher lease.

## Incident triage

A live main-to-worktree handoff exposed two gaps in the existing continuous
handoff contract:

1. The launcher terminates the previous Client tree without waiting for the old
   VM service and managed launch identity to disappear. Target readiness can
   therefore be satisfied by the old Client, and `_managedClientPids` can write
   its PID because it filters only by VM port plus launcher id/nonce, not by
   target source identity. The manifest reaches `complete` while the replacement
   Client is still starting; when the old process exits, status reports
   `client PIDs do not match lease`.
2. Startup checkpoint restoration recognizes a requester-bound deferred result
   as safe but does not return that tool-call id to `AgentRunner`. The runner
   trims history to the pre-model checkpoint, removes the durable assistant
   tool-call batch, and starts another model request instead of resolving the
   existing launcher manifest. The model can then issue a second switch during
   the Agent-before-Client startup window and receive `the selected agent has no
   discoverable clients` even though the first transaction succeeds.

These behaviors contradict the documented exact-once deferred-result contract
and target-group health requirement. This task corrects the implementation and
adds regression coverage; it does not weaken switch authorization or ownership
validation.

## Implementation

- Return requester-bound deferred tool-call ids from checkpoint restoration.
- Preserve the complete durable assistant tool-call batch across history trim
  when it owns deferred or ambiguous interrupted calls.
- Resume that batch through `ToolExecutionCoordinator`, allowing deferred
  descriptors to resolve without replaying the external shell mutation and
  preserving original batch order.
- During source replacement, wait until each previous managed Client identity
  and VM-service endpoint is gone before starting a target Client on the same
  reserved port.
- Verify target Clients by VM port, launcher id/nonce, and the expected target
  workspace source marker before writing their PIDs into the lease or recording
  terminal `complete`.
- Apply the same identity verification to rollback so restored lease ownership
  is exact.

## Verification

- Focused checkpoint/coordinator unit tests prove deferred ids survive restore
  and the original assistant batch is resolved once rather than removed or
  replayed.
- Focused `sanad-dev` tests prove stale previous identities cannot satisfy
  target readiness or lease PID collection.
- Agent analyzer and focused Agent tests pass.
- Flutter analyzer and focused `sanad_dev` unit tests pass.
- Existing runtime ownership and source-switch QA documentation describes the
  corrected boundaries.
- `graphify update .` is run if Graphify is available; absence is recorded.

## Verification evidence

- `fvm dart analyze` — passed.
- `fvm flutter analyze` — passed.
- `fvm dart test test/engine/agent_runner_test.dart test/engine/history_healer_test.dart test/interfaces/runtime/session_restart_checkpoint_test.dart` — 72 tests passed.
- `fvm flutter test test/unit/scripts/sanad_dev_runtime_switch_test.dart test/unit/scripts/sanad_dev_runtime_ownership_test.dart test/unit/scripts/sanad_dev_process_state_test.dart` — 33 tests passed.
- Graphify update was skipped because this worktree has no
  `graphify-out/graph.json`; creating a new graph is outside this task.
- Authorized isolated process-level source handoff — passed: the original
  command returned `Switch complete`; post-handoff status reported the target
  Agent and Client source, one exact Client PID, `Runtime class: managed`, and
  no cross-owned or unverifiable Clients. The isolated runtime was then stopped
  and its temporary target worktree/branch removed.

## Definition of Done

- [x] A deferred switch manifest resolves into the original tool-call result
  after recovery with no second shell execution.
- [x] History trim preserves the owning assistant tool-call batch.
- [x] A previous Client still visible on the retained VM port cannot satisfy
  target startup.
- [x] A terminal complete handoff lease accepts only target-workspace Client
  PIDs.
- [x] Rollback records only verified previous-workspace Client PIDs.
- [x] Focused tests and analyzers pass.
- [x] Technical and QA documentation is updated.
- [x] An authorized isolated process-level source handoff confirms the complete
  launcher/Agent/Client recovery path.
