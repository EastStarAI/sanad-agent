# Jev-assisted conversation automation

Load this reference for a reusable one-message flow that selects a Sanad device and conversation, selects an exact provider/model, sends once, verifies the new response, and returns to the origin. For ordinary execution, do not load the full `jev-dual-brain-automation` skill: the runner imports its tested primitives directly. Load that skill only when designing, modifying, or diagnosing custom dual-brain automation.

## Canonical runner

```text
.agents/skills/sanad-client-tester/scripts/sanad_conversation_workflow.py
```

Use `--help` only when a required argument is unknown or the runner contract is being developed; it is not a routine preflight command.

## Fast execution contract

When all required inputs are known, invoke the canonical runner as the first execution command. Do not precede it with `sanad-dev status`, `sanad-dev ui snapshot/find`, log reads, or manual Jev calls. Those checks duplicate work already performed inside the runner and add latency without increasing safety.

One runner invocation owns the complete standard workflow. Its successful JSON is acceptance evidence. If it fails, do not rerun it automatically; classify the failed phase and load only the diagnostic reference needed for that failure.

The runner accepts:

- one exact target device;
- exactly one conversation mode: new conversation, durable conversation id, or exact visible title;
- an optional exact workspace only for new conversations;
- one exact provider/model pair;
- one message and bounded response timeout;
- one explicit origin device unless `--leave-at-target` is intentionally selected.

Prefer durable conversation ids because visible titles may be truncated or duplicated.

## Ownership boundary

Deterministic code owns phase order, exact selectors, one-shot conversation creation/send admission, same-connection event waiting, event-body evidence, timeout handling, JSON output, and restoration of the captured origin after success or failure. Jev performs only one narrow semantic judgment over the newly rendered assistant body. Jev does not select devices, invent keys, retry sends, or authorize destructive actions.

The runner:

1. captures exactly one selected origin conversation before mutation;
2. resolves devices by `sidebar_device_item_<exact name>`;
3. resolves workspace creation through one exact `workspace-group:<id>` and `sidebar_new_conversation_btn:<id>`;
4. skips provider/model selection only when `model_selector_btn` already renders the exact `Provider | model`;
5. refuses to overwrite a non-empty `chat_input`;
6. reserves conversation creation and send as irreversible one-shot phases;
7. waits on `stop_message_btn` lifecycle in one Driver batch and then reads `message_bodies`;
8. requires a new non-empty `assistant_message_body:<eventId>` and uses exact send evidence for the user body;
9. requires Jev semantic probability of at least `0.75`;
10. restores the origin after success or failure, preserving the primary error and reporting a separate return failure when both occur.

It does not paginate hidden conversations, infer truncated titles, use coordinates, or retry an ambiguous send.

## Diagnostic escalation

Escalate narrowly after failure:

- runtime ownership or discovery failure → load `runtime-and-worktrees.md` and run the minimum status check;
- missing, duplicate, or stale UI key; return-navigation failure → load `interactive-ui-testing.md` and inspect one current snapshot;
- Jev API, confidence, phase-ledger, or circuit-breaker failure → load `jev-dual-brain-automation`;
- ambiguous send outcome → inspect current event evidence without sending again.

Do not load all diagnostic references together. Begin from the runner's failed phase and stop once evidence explains it.

## Result and compatibility

Success emits JSON containing the assistant event key, `assistant_response`, Jev probability, optional user event key, and `returned_to_origin`.

`temp/jev_sanad_conversation_runner.py` remains a compatibility forwarder to the canonical Client Tester script. New automation and documentation must use the canonical path.
