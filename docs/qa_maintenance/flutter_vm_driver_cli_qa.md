---
title: "Flutter VM Driver CLI QA Matrix"
description: "Static, managed-runtime, live interaction, and platform compatibility coverage for agent-driven Flutter control."
---

# Flutter VM Driver CLI QA Matrix

## Static and Unit Coverage

| Scenario | Expected result |
| --- | --- |
| CLI help without a running Client | Succeeds without VM discovery |
| `enter-text` with only a key and no text | Fails before connecting; the key value is never treated as input text |
| Missing batch recipe | Fails before connecting with a bounded error |
| Explicit VM endpoint | Is preserved exactly and does not trigger process-table discovery |
| Active authentication URL | The controller selects the isolate advertising `ext.sanad_client.auth_url` and returns the HTTP(S) URL from that Client only |
| Missing authentication challenge | `auth-url` exits nonzero with a bounded error and no fallback to another isolate, Client, browser, or heap object |
| Invalid authentication URL | Non-HTTP(S) values are rejected without echoing the rejected value |
| Authentication URL output | Human mode writes only the URL to stdout; the value is absent from general snapshots and persisted runtime surfaces |
| Element query | Matches key, tooltip, type suffix, and free-text query deterministically |
| Rich text extraction | `Text.rich`, `RichText`, and `SelectableText.rich` expose their rendered plain text rather than an empty `Text.data` value |
| Message body identity | User and assistant Markdown each render exactly one event-scoped `*_message_body:<eventId>` key |
| Markdown consolidation | Multi-block Markdown text is joined in display order on the keyed message-body row without duplicate descendant rows |
| Analyzer and formatter | All changed Client and script sources pass |

## Managed Runtime Coverage

| Scenario | Expected result |
| --- | --- |
| Current worktree has no live driver client | `sanad-dev ui` fails closed and explains the driver prerequisite |
| Current worktree has a live driver client | Its recorded VM endpoint is forwarded to the standalone CLI |
| Current worktree has multiple live driver Clients | Automatic selection fails closed; `auth-url` and other commands require the intended Client's explicit VM endpoint |
| Explicit VM endpoint is supplied | The caller endpoint is preserved, including equals-style options |
| Windows host | FVM child execution uses shell resolution for the platform wrapper |
| Help request with no runtime | Help remains available |

## Live Interaction Coverage

| Scenario | Expected result |
| --- | --- |
| Snapshot | Returns keyed/textual elements and the current worktree badge |
| Fresh macOS authentication | After UI-driven sign-out and sign-in, `auth-url` for the explicit macOS VM can be captured directly into a temporary shell variable, opened in the automation browser, unset, and followed by a Client snapshot proving Cloud reconnection |
| Completed or absent authentication | The same explicit VM returns a nonzero `auth-url` result after the in-memory challenge is cleared |
| Tooltip-wrapped action | Actionable child contains the inherited tooltip |
| Selected semantic action | Keyed output reports semantic label, button role, and selected state without duplicate wrapper rows |
| Obscured text field | Snapshot omits its current value |
| Missing `--within` scope | Fails; it never broadens to the complete tree |
| Exact keyed tap | Scrolls into view, taps the requested element, and returns coordinates |
| Invalid tap index | Fails with match count; it never clamps to another element |
| Keyed offset scroll | Targets the exact Scrollable, emits forward/reverse user intent, returns post-motion offset plus min/max extents, and activates the same pagination/follow rules as mouse or trackpad input. |
| Scroll until visible | Repeats through Flutter Driver until the target is visible or times out |
| Driver starts before any automation command | Flutter Driver text emulation is disabled; clicking an editable field accepts normal physical-keyboard characters and system IME input. |
| Keyed automated text entry | `sanad-dev ui enter-text` focuses the exact field and updates its `EditableTextState` through the Sanad extension; follow-up inspection shows the new value without echoing it in the action result. |
| User message inspection | After one send, exact-key `find` returns one `user_message_body:<eventId>` element whose `text` contains the rendered message without clipboard access. |
| Assistant Markdown inspection | After response completion, exact-key `find` returns one `assistant_message_body:<eventId>` element whose `text` contains every displayed Markdown block once and omits footer metadata. |
| Message key disambiguation | Two mounted user or assistant messages remain independently addressable by event id; a lookup never resolves a generic kind-only key. |
| Automated entry followed by physical typing | The system text channel was never mocked, so physical typing remains functional after the automated command. |
| Older instrumented Client without the Sanad text extension | Controller falls back to legacy Flutter Driver `enterText` and reports both bounded errors if neither path succeeds. |
| Text entry during animation/streaming | Runs unsynchronized where legacy fallback is required and remains responsive. |
| Wait for presence/absence | Returns success only for the requested terminal condition |
| Screenshot | Produces a non-empty PNG outside tracked source artifacts |
| Batch JSON mode | Emits exactly one parseable JSON result and a nonzero status when any step fails |

## Platform Matrix

Desktop macOS is the required live PR gate because it addresses the accessibility gap. Windows and Linux require static/unit coverage plus a managed-runtime smoke test when runners are available. Android, iOS, and web are compatibility targets: verification requires the driver entry point and an explicitly reachable VM Service endpoint; no claim of arbitrary installed-app control is made.

## Residual Risk

Flutter Driver remains a development-only protocol and may vary across Flutter upgrades. Tests should pin selector behavior and VM connection semantics to the repository's FVM version. Production builds must not expose the driver service extensions.
