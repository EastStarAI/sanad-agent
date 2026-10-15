---
title: "Jev Sanad UI Automation"
description: "Usage and safety boundary for the tracked Jev Sanad conversation runner."
---

# Jev Sanad UI Automation

## Scope

`.agents/skills/sanad-client-tester/scripts/sanad_conversation_workflow.py` is the canonical tracked runner for driving one managed, driver-enabled Sanad Client. It accepts an exact target device, either a new conversation or one visible existing conversation, an exact provider/model pair, and one message. It verifies a newly rendered response and can return to the conversation selected before execution. `temp/jev_sanad_conversation_runner.py` remains a thin compatibility forwarder for prior local invocations.

The runner is intentionally hybrid:

- deterministic code owns phases, exact selectors, one-shot conversation creation and send admission, event waiting, event-body verification, and return navigation; related actions in one phase use one Driver batch connection to avoid per-command VM reconnection delay;
- Jev performs only a final semantic judgment that the newly rendered assistant response addresses the supplied message;
- missing, duplicate, hidden, or mismatched selectors fail closed instead of being guessed.

## Execution modes

For a supported standard conversation request with all required inputs, the canonical runner is the fast path and should be the first execution command. Do not precede it with separate `sanad-dev status`, UI snapshot/find, log reads, `--help`, or manual Jev calls: runtime resolution, initial observation, selector admission, response evidence, semantic verification, and return checks already belong to that invocation.

Use manual runtime/UI diagnostics only after a runner failure or for a workflow outside its contract. Diagnose from the failed phase, load only the relevant focused reference, and never retry an ambiguous send.

## Input contract

The canonical runner accepts an exact target device, exact provider and model, one message, and exactly one conversation mode: new conversation (optionally bound to one exact workspace), durable conversation id, or exact visible title. Workspace selection is rejected for existing conversations. Durable conversation id is preferred because rendered sidebar titles may be truncated or duplicated.

An exact origin device is required when return navigation is enabled. Return may be explicitly disabled. Return is otherwise strict: the runner captures the selected origin conversation key before any mutation and requires the supplied origin device because the current unkeyed device header does not expose a reliable active-device value through the driver snapshot. Use the canonical script's `--help` output as the argument reference; the retained `temp/` note documents compatibility examples.

## Verification and safety

The runner must:

1. capture exactly one selected origin conversation before switching devices;
2. resolve each device option by `sidebar_device_item_<exact name>`;
3. for a workspace-bound new conversation, resolve one exact `workspace-group:<id>` and use `sidebar_new_conversation_btn:<id>`; skip that action only when no existing row is selected and `workspace_selector_btn` already shows the requested workspace;
4. inspect the active `Provider | model` first and skip the picker when it already matches; otherwise verify availability by exact rendered `Provider / model` text before selecting it;
5. refuse to overwrite a non-empty composer;
6. reserve new-conversation creation and send as irreversible one-shot phases;
7. wait on `stop_message_btn` lifecycle through `sanad-dev ui wait-for` rather than model or snapshot polling;
8. require one new exact `user_message_body:<eventId>` and a new non-empty `assistant_message_body:<eventId>`;
9. require Jev semantic probability of at least `0.75`;
10. attempt origin restoration after success or failure, preserve the primary failure when restoration succeeds, and report both errors when restoration also fails;
11. treat the successful same-connection exact-text wait as user-send evidence when the user message-body key is not mounted, while still requiring a new assistant body before success.

The script does not paginate hidden conversations, infer truncated titles, retry a possibly completed send, or use coordinates. Its implementation and focused tests are owned by Sanad Client Tester; the reusable Jev skill owns only the general judgment and workflow-safety primitives, and the compatibility entry point must remain behaviorally equivalent.
