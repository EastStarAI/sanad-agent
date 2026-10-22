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
| Batch message-body evidence | `message_bodies` returns only event-scoped user/assistant bodies, at most the latest 50, with total count and explicit truncation metadata |
| Markdown consolidation | Multi-block Markdown text is joined in display order on the keyed message-body row without duplicate descendant rows |
| Element enabled state | Buttons, icon buttons, list tiles, ink wells, popup menus, and text fields report `enabled` from their live callbacks (keyed wrappers resolve the first descendant control); widgets without enabled state omit the field, and human output marks only disabled rows `(disabled)` |
| Workspace browser driver keys | Each folder row exposes `workspace_browser_folder_row:<name>`, and its rename/delete buttons expose `workspace_browser_rename_button:<name>` / `workspace_browser_delete_button:<name>`; mutation buttons are absent at the managed root |
| Permission card driver keys | Options expose `permission_option_once`, `permission_option_session`, `permission_option_workspace`, and `permission_option_deny`; the deny comment and submit expose `permission_deny_comment_input` and `permission_deny_submit_button` |
| Secret request driver keys | The composer secret card exposes `secret_request_card`, `secret_request_reason`, one `secret_input_<NAME>` per field, `secret_toggle_visibility_<NAME>` for masked fields, `secret_replaces_<NAME>` when a stored value is replaced, `secret_request_error`, `secret_request_save_btn`, and `secret_request_skip_btn`. `sanad-dev ui enter-text` must use dummy values only; inspection never echoes a field value |
| Workspace security driver keys | Composer permission menu items expose `composer_permission_mode_default` and `composer_permission_mode_full_access`; the Workspace Settings security card segments expose `workspace_security_mode_direct`, `workspace_security_mode_protected`, `workspace_security_discovery_owner_only`, and `workspace_security_discovery_disabled`, each reporting `selected` through `Semantics(selected:)`. The sidebar `workspace_settings_btn` stays hover-only (an invisible tappable target would invite accidental taps); drivers open Workspace Settings from the Settings navigation instead |
| Analyzer and formatter | All changed Client and script sources pass |
| Snapshot generation | Two consecutive `snapshot --json` invocations report a strictly increasing `generation` and a stable `signature` for an unchanged tree |
| Fresh snapshot | `snapshot --fresh` re-captures until two consecutive trees agree and reports `fresh: true` |
| Wait with elapsed time | `wait-for --key` returns `duration_ms` and `data.waited_ms`, and succeeds after a late element appears |
| Wait for absence | `wait-for --absent` fails closed when the element persists past `--timeout` |
| Offstage scroll target | `scroll --until-visible` fails fast with `target offstage/not found; navigate first` instead of hanging, and succeeds without scrolling when the target is already rendered |
| Tap post-condition | A tap whose tree does not change fails with `verified: none` and names `--expect` and `--no-verify`; `--expect`/`--expect-absent` are asserted against the settled tree; `--no-verify` accepts a deliberate no-op |
| Tap result shape | JSON reports `key`, `x`, `y`, `generation`, and `duration_ms` in addition to the existing fields |
| Enter-text post-condition | A changed rendered value verifies as `text` without echoing the value; an obscured field without an observable tree change fails and offers `--no-verify` |
| Wall-clock kill | A driver child that overruns the computed cap is killed and the command exits `124` with a bounded diagnostic |
| Artifact cache | A source-matched native artifact is compiled once per fingerprint, reused afterwards, replaced after a source change, and pruned when stale |
| Batch action plus wait | One `batch` recipe chains a tap with a `wait_for` step and returns both results from a single connection |

## Managed Runtime Coverage

| Scenario | Expected result |
| --- | --- |
| Current worktree has no live driver client | `sanad-dev ui` fails closed and explains the driver prerequisite |
| Current worktree has a live driver client | Its recorded VM endpoint is forwarded to the standalone CLI |
| Current worktree has multiple live driver Clients | Automatic selection fails closed; `auth-url` and other commands require the intended Client's explicit VM endpoint |
| Explicit VM endpoint is supplied | The caller endpoint is preserved, including equals-style options |
| Windows host | FVM child execution uses shell resolution for the platform wrapper |
| Help request with no runtime | Help remains available |
| Transient missing Client | Discovery is retried once before the missing-Client failure is reported |
| Owning window not frontmost | The owner bundle is activated before dispatch; activation failure never blocks the action and never raises a system prompt |
| Missing Client package configuration | Fails closed with the setup recovery command instead of a compile error |

## Live Interaction Coverage

| Scenario | Expected result |
| --- | --- |
| Snapshot | Returns keyed/textual elements and the current worktree badge |
| Fresh macOS authentication | After UI-driven sign-out and sign-in, `auth-url` for the explicit macOS VM can be captured directly into a temporary shell variable, opened in the automation browser, unset, and followed by a Client snapshot proving Cloud reconnection |
| Completed or absent authentication | The same explicit VM returns a nonzero `auth-url` result after the in-memory challenge is cleared |
| Tooltip-wrapped action | Actionable child contains the inherited tooltip |
| Disabled keyed control | `ui snapshot` and `ui find` report `enabled: false` (JSON) or `(disabled)` (human) for a keyed control whose callback is absent, and `enabled: true` once it becomes actionable |
| Selected semantic action | Keyed output reports semantic label, button role, and selected state without duplicate wrapper rows |
| Obscured text field | Snapshot omits its current value |
| Missing `--within` scope | Fails; it never broadens to the complete tree |
| Exact keyed tap | Scrolls into view, taps the requested element, and returns coordinates |
| Invalid tap index | Fails with match count; it never clamps to another element |
| Keyed offset scroll | Targets the exact Scrollable, emits forward/reverse user intent, returns post-motion offset plus min/max extents, and activates the same pagination/follow rules as mouse or trackpad input. |
| Scroll until visible | Repeats bounded offset scrolling plus tree probes until the target is visible, or fails with `target offstage/not found; navigate first` inside the deadline |
| Driver starts before any automation command | Flutter Driver text emulation is disabled; clicking an editable field accepts normal physical-keyboard characters and system IME input. |
| Keyed automated text entry | `sanad-dev ui enter-text` focuses the exact field and updates its `EditableTextState` through the Sanad extension; follow-up inspection shows the new value without echoing it in the action result. |
| User message inspection | After one send, exact-key `find` returns one `user_message_body:<eventId>` element whose `text` contains the rendered message without clipboard access. |
| Assistant Markdown inspection | After response completion, exact-key `find` returns one `assistant_message_body:<eventId>` element whose `text` contains every displayed Markdown block once and omits footer metadata. |
| Message key disambiguation | Two mounted user or assistant messages remain independently addressable by event id; a lookup never resolves a generic kind-only key. |
| Automated entry followed by physical typing | The system text channel was never mocked, so physical typing remains functional after the automated command. |
| Older instrumented Client without the Sanad text extension | Fails closed with a bounded extension error; text entry never degrades to an unscoped legacy path. |
| Action during animation/streaming | Tree probes replace Flutter Driver frame synchronization, so a busy Client still answers inspection, waits, and verification inside the deadline. |
| Wait for presence/absence | Returns success only for the requested terminal condition |
| Screenshot | Produces a non-empty PNG outside tracked source artifacts |
| Batch JSON mode | Emits exactly one parseable JSON result and a nonzero status when any step fails |
| Same-connection response evidence | A send/wait/`message_bodies` batch captures the target conversation before closing its shared Driver connection, avoiding a follow-up navigation race |

## Platform Matrix

Desktop macOS is the required live PR gate because it addresses the accessibility gap. Windows and Linux require static/unit coverage plus a managed-runtime smoke test when runners are available. Android, iOS, and web are compatibility targets: verification requires the driver entry point and an explicitly reachable VM Service endpoint; no claim of arbitrary installed-app control is made.

## Residual Risk

Flutter Driver remains a development-only protocol and may vary across Flutter upgrades. Tests should pin selector behavior and VM connection semantics to the repository's FVM version. Production builds must not expose the driver service extensions.
