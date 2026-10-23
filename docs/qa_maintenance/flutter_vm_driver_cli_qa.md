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
| Generation concurrency | The counter is incremented under an advisory lock keyed by the resolved endpoint, so concurrent invocations never return the same value and no endpoint token reaches the filesystem |
| Fresh snapshot | `snapshot --fresh` re-captures until two consecutive trees agree and reports `fresh: true` with `settled: true` |
| Fresh snapshot that never settles | `snapshot --fresh` still returns the last tree but reports `fresh: true` with `settled: false` instead of claiming quiescence |
| Default snapshot freshness | A snapshot without `--fresh` reports `fresh: false` and omits `settled`, so the field is never read as a failed quiesce |
| Verification field types | Every action result (single action and every batch step) reports `verified` as a JSON boolean and `verification` as one of `key`, `present`, `absent`, `text`, `tree`, `no_observable_change`, `none`, `type_census`; no channel is emitted as a string into `verified` |
| Verification channel stability | The same physical outcome reports the same `verification` with and without `--verify`: an inert tap is `no_observable_change` in both cases, and only the exit status and success flag differ |
| Observation-only result | A batch `snapshot`, `sleep`, or `message_bodies` step still reports both fields, with `verified: false` and `verification: none` because the step asserts no post-condition |
| Disabled verification | `tap --no-verify` and `enter-text --no-verify` report `verified: false` with `verification: none` instead of omitting the fields |
| Cold artifact cost | The first `ui` call after a source or dependency change reports `build_ms` equal to the compile time; a call served by the cached artifact omits `build_ms` |
| Wait with elapsed time | `wait-for --key` returns `duration_ms` and `data.waited_ms`, and succeeds after a late element appears |
| Wait for absence | `wait-for --absent` fails closed when the element persists past `--timeout`, reporting `<target> is still present after Nms; absence not observed` plus the probe count, never a bare timeout |
| Type absence proof | `wait-for --absent --type` succeeds only when the rendered type census shows the type is not rendered, and fails closed with a `type census truncated` message rather than a timeout diagnostic when the census was truncated |
| Type absence that arrives late | A rendered type that stops being rendered inside `--timeout` is reported as a success (`verification: absent`, `data.evidence: type_census`); the wait is never capped at the first census |
| Type absence that persists | A type still rendered at the deadline fails with `<type> is still rendered (proven by the rendered type census) after Nms; absence not observed`, `data.evidence: type_census`, `data.still_rendered: true`, and `verification: type_census` |
| Fail-fast absence | `wait-for --type --absent --no-wait` (or `no_wait: true` on a batch step) judges the first census and returns the same evidence-bearing failure in one probe, with `after a single check (Nms)` in the message |
| Census bound | The rendered type census is bounded by the elements it walks (20000) and not by the number of distinct rendered types, so a tree with hundreds of distinct widget types is still a complete census |
| Rendered but uninspected type | `wait-for --type CircularProgressIndicator` fails immediately with `<type> is still rendered (proven by the rendered type census) …, but it is not inspected`, `data.evidence: type_census`, and `verification: type_census` instead of waiting out the timeout |
| Offstage scroll target | `scroll --until-visible` fails fast with `target offstage/not found; navigate first` instead of hanging, and succeeds without scrolling when the target is already rendered |
| Plain tap on an inert widget | Exits `0` with `verified: false` and `verification: no_observable_change`; the message contains `tap dispatched; no observable change` and warns against a blind retry |
| Strict tap post-condition | `tap --verify`, `--expect`, or `--expect-absent` make an unchanged tree a failure with `verified: false`, `verification: no_observable_change`, and the same dispatched-once wording; `--no-verify` accepts a deliberate no-op and reports `verification: none` |
| Tap baseline placement | The controller reveals the selector (`ext.sanad_client.reveal`) before capturing the baseline, so an auto-scroll that moves bounds is not credited to the tap as `verified: tree` |
| Unrevealed baseline | A Client that does not register `ext.sanad_client.reveal` still taps and verifies, and both the verified and the failed messages state that verification may be affected by auto-scroll |
| Tap result shape | JSON reports `key`, `x`, `y`, `generation`, and `duration_ms` in addition to the existing fields |
| Enter-text post-condition | A changed rendered value verifies as `text` without echoing the value; an obscured field verifies as `tree` when the widget tree changes and fails with `--no-verify` offered when it does not |
| Wall-clock kill | A driver child that overruns the computed cap is killed and the command exits `124` with a bounded diagnostic |
| Wall-clock budget | The cap includes each action's post-delay and verify window, and a batch recipe adds every step's own timeout, delay, verify window, and sleep |
| Explicit wall clock | `--wall-timeout <sec>` replaces the derived cap for the whole child process, is never forwarded to the driver, and is documented in `sanad-dev ui -h` under `Launcher Options` |
| Batch deadline source | A step without its own timeout runs under the batch `--timeout`, so the launcher's budget and the driver's enforced deadline are the same value; a step with its own longer timeout keeps it and the transport timeout follows the longest step |
| Process-tree kill | A killed driver child leaves no live descendant, so the `dart` grandchild behind an `fvm` wrapper cannot keep acting |
| Compile deadline | A driver CLI compilation that exceeds its deadline is killed with its process tree and falls back to the JIT path |
| Partial batch evidence | A batch killed at the wall clock reports the steps that completed, both as persisted per-step evidence and as a partial result (`timed_out`, `partial`, `steps_total`, `completed`) |
| Artifact cache | A source-matched native artifact is compiled once per fingerprint, reused afterwards, replaced after a source change, and pruned when stale while a fresh staging file of another invocation survives |
| Artifact dependency invalidation | Changing `client/pubspec.lock`, `client/.dart_tool/package_config.json`, `.fvmrc`, or the Dart SDK version produces a new artifact and a rebuild |
| Artifact disappearance | An artifact that disappears after the cache check falls back to the JIT path instead of failing the action |
| Launcher argument fidelity | A driver value that equals a launcher flag (for example `enter-text --text --home`) is forwarded verbatim, while launcher flags before the sub-command or after `--` are stripped |
| Batch action plus wait | One `batch` recipe chains a tap with a `wait_for` step and returns both results from a single connection |

## Managed Runtime Coverage

| Scenario | Expected result |
| --- | --- |
| Current worktree has no live driver client | `sanad-dev ui` fails closed and explains the driver prerequisite |
| Current worktree has a live driver client | Its recorded VM endpoint is forwarded to the standalone CLI |
| Current worktree has multiple live driver Clients | Automatic selection fails closed; `auth-url` and other commands require the intended Client's explicit VM endpoint |
| Explicit VM endpoint is supplied | The caller endpoint is preserved, including equals-style options |
| Windows host | FVM child execution uses shell resolution for the platform wrapper |
| Help request with no runtime | Help remains available, and `sanad-dev ui -h` documents the launcher-only options (`--wall-timeout`, `--home`, `--activate`, `--no-activate`) together with the `verified`/`verification` contract |
| Transient missing Client | Discovery is retried once before the missing-Client failure is reported |
| Owning window not frontmost | The owner bundle is activated before a UI-changing command (tap, enter-text, scroll, batch) and never before snapshot, find, wait-for, or screenshot; activation failure never blocks the action and never raises a system prompt |
| Owning window liveness | Activation is skipped when the discovered pid has exited, no longer belongs to that bundle, or shares the bundle with a second live instance; `open` is never called and no new Client instance is launched |
| Activation opt-out | `--no-activate` disables activation for the invocation without changing the forwarded action |
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
| Inert widget tap | A `ui tap --key <inert_control>` exits `0` with `verified: false` and `verification: no_observable_change`; the same command with `--verify` exits nonzero with `tap dispatched; no observable change` and the same `verification: no_observable_change` |
| Obscured field entry | `ui enter-text --key <password_field> --text <dummy>` verifies through a tree change when the Client updates the field's visible state, and otherwise fails with the tree-check explanation and no echoed value |
| Unsupported type wait | `ui wait-for --type CircularProgressIndicator --timeout 5` fails within seconds with `<type> is still rendered (proven by the rendered type census) … is not inspected` and `verification: type_census` |
| Persisting type absence | `ui wait-for --type CircularProgressIndicator --absent --timeout 10` runs the full deadline and then fails with `<type> is still rendered (proven by the rendered type census) after Nms; absence not observed`, `data.evidence: type_census`, and `data.still_rendered: true`; adding `--no-wait` returns the same failure in one probe |
| Screenshot | Produces a non-empty PNG outside tracked source artifacts |
| Batch JSON mode | Emits exactly one parseable JSON result and a nonzero status when any step fails |
| Same-connection response evidence | A send/wait/`message_bodies` batch captures the target conversation before closing its shared Driver connection, avoiding a follow-up navigation race |

## Platform Matrix

Desktop macOS is the required live PR gate because it addresses the accessibility gap. Windows and Linux require static/unit coverage plus a managed-runtime smoke test when runners are available. Android, iOS, and web are compatibility targets: verification requires the driver entry point and an explicitly reachable VM Service endpoint; no claim of arbitrary installed-app control is made.

## Residual Risk

Flutter Driver remains a development-only protocol and may vary across Flutter upgrades. Tests should pin selector behavior and VM connection semantics to the repository's FVM version. Production builds must not expose the driver service extensions.
