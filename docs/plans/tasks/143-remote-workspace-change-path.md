---
title: "Task 143 — Remote Change Path through the confined browser"
description: "Offer Workspace Settings → Change Path for a device reached over the cloud by reusing the Task 123 confined folder browser and the Agent's existing preview-ticketed workspace.relocate, with an in-root notice, one confirmation line naming the resolved target, and a specific out-of-root message."
status: completed
current_gate: "closed — PR #331 merged as 50add1a3; live acceptance steps 1–4 and 6–8 PASS, step 5 PARTIAL (the D7 matrix is not reachable with the available live tooling)"
remaining_estimate: 0%
base_commit: 23b7a825
depends_on: "Task 123 (confined remote browser, done); Task 140 (settings pages split, done)"
delivery: own PR #331 (merged as 50add1a3)
---

# Task 143 — Remote Change Path

## Goal

A Client inspecting a device reached over the cloud can change that workspace's folder from Settings →
Workspace → Change Path, using the same confined in-app browser Task 123 shipped, and only into a folder
strictly inside the device Home's managed workspaces root. The same-desktop local device keeps the native
macOS picker unchanged.

Client only. No Agent, protocol, or Gateway change.

## Verified starting point (2026-10-24, `23b7a825`)

| Fact | Evidence |
|---|---|
| The Agent already relocates remotely end to end: managed confinement, preview, ticket, `stale_confirmation` | `agent/lib/interfaces/runtime/workspace_file_system_coordinator.dart` (`resolveManagedDirectory`, `requireManagedWorkspaceDirectory`); `agent/lib/interfaces/runtime/local_workspace_runtime_service.dart:243-275`; `agent/lib/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart:124-168` |
| Relocate is metadata only: one `workspaces.path` update, no folder is moved, sessions survive by UUID | `agent/lib/interfaces/runtime/local_workspace_runtime_service.dart` (`_relocateWorkspaceUnchecked`) |
| A running turn keeps the root it captured when its catalog was built; only the next turn re-resolves it | `agent/lib/capabilities/runtime/local_runtime_catalog.dart:225-259` (`_resolveTargetWorkspacePath`) |
| Rejections reach the Client as a coded `error` (`path_not_allowed`, `workspace_in_use`, `stale_confirmation`) | `agent/lib/interfaces/platforms/sanad_gateway/handlers/support/agent_event_envelope.dart:43-58`; `client/lib/features/conversations/domain/models/workspace_command_failure.dart` |
| The transport already performs the preview → ticketed retry for `workspace.relocate` | `client/lib/features/conversations/data/transport/workspace_commands.dart:182-215` |
| The cache patches the workspace only from the authoritative reply | `client/lib/features/conversations/data/repositories/conversation_cache_repository.dart:401-413` |
| Only two Client gates block remote Change Path: the button gate and the picker's local-only branch | `client/lib/features/settings/presentation/screens/settings_screen.dart:414`; `client/lib/utils/workspace_picker_helper.dart:29-46` |
| The browser is hard-wired to "a folder that *becomes* a workspace": no mode, CTA "Use This Folder", disabled at the root | `client/lib/features/conversations/presentation/widgets/workspace_browser_dialog.dart:303,529` |
| Managed browse with an empty path opens the root; a `workspace_id` scope rewrites `root_path` to the workspace folder, so it cannot serve a relocate target picker | `agent/lib/interfaces/runtime/workspace_file_system_coordinator.dart:126-165` |
| No test covers Settings Change Path | `grep -rn "Change Path" client/test` returns nothing |

## Binding decisions (2026-10-24)

| # | Decision |
|---|---|
| D1 | Offer remote Change Path: **option A**, reusing the Task 123 confined browser. Option B is rejected (the native picker stays for local); option C is rejected. |
| D2 | Target scope is unchanged on the Agent: strictly inside `<SANAD_HOME>/workspaces`. The UI says so before the user picks. |
| D3 | One explicit confirmation line naming the resolved target, then send. The Agent's preview ticket stays invisible. |
| D4 | The browser opens at the workspace's current folder when it is inside the root, otherwise at the root. |
| D5 | In-flight work is allowed, with no new lock. A running turn keeps the old folder until its next turn. |
| D6 | Localize only the strings this adds or changes, through `client/lib/l10n/app_en.arb` and `app_ar.arb`. |
| D7 | Out-of-root target: the specific copy "This device can only change to a folder inside its Sanad workspaces root" (en + ar) instead of the daemon reason. |
| D8 | Same-desktop shape is unchanged: `isLocalReachable` keeps the native picker. The same-device cloud-only shape stays unsupported (`docs/technical/communication_protocols.md` §3.2). |

## Work

### W1 — one picker, two routes

`WorkspacePickerHelper.pickWorkspacePath` gains `remoteBrowser` (`WorkspaceBrowserCallbacks?`) and
`remoteStartPath`. A device that is not local-reachable but is online delegates to the existing
`openRemoteFolderBrowser`; one dialog, one path, no second picker. A missing `remoteBrowser` keeps today's
refusal so a future caller cannot silently drop the pick.

### W2 — the dialog carries the change mode

`WorkspaceBrowserDialog` gains `mode` (`createWorkspace` | `changePath`) and `initialPath`. In change mode the
CTA reads "Change to This Folder" (from `AppLocalizations`, not a caller-supplied literal), the CTA stays
disabled at the root, a notice states the in-root scope (D2), and the first load starts at `initialPath`,
falling back to the device root when that folder is outside the root or gone (D4). Create mode is unchanged.

### W3 — Settings wiring, gate, out-of-root copy

- `settings_screen.dart` passes `WorkspaceBrowserCallbacks.forDevice(_cache, selected)` bound to the
  **inspected** device, never the active conversation's.
- The gate becomes `isOnline`, matching Remove Workspace; a local-reachable device still takes the native
  picker through the same helper (D8).
- The flow lives in one presentation owner (`settings_pages/workspace_change_path.dart`): pick → one
  confirmation line naming the resolved target (D3) → `relocateWorkspace` → error mapping, where
  `path_not_allowed` renders the D7 copy and every other code keeps the daemon reason.

### W4 — tests

New `client/test/widget/settings/workspace_change_path_test.dart`:

- the Change Path action is offered for an online remote device and absent offline, and the page renders the
  button only when the action exists;
- a local-reachable device still takes the native-picker branch and never opens the browser;
- a remote pick opens the browser with callbacks bound to the inspected device, at the workspace's current
  folder, and cancel sends nothing;
- a pick plus confirm sends exactly `workspace_id` + `new_path`, then the ticketed retry;
- `path_not_allowed` renders the D7 copy; another coded rejection keeps the daemon reason.

Regressions: the dialog's create mode (existing suite) and the helper's three existing callers (composer,
sidebar, schedules editor). Localization: en + ar, with an RTL pump of the dialog in change mode.

### W5 — docs in this PR

`client/lib/features/settings/AGENTS.md` (replace "Remote Change Path is not offered here"),
`client/lib/features/conversations/presentation/AGENTS.md` (the shared-picker paragraph),
`docs/technical/workspace_identity_protocol.md` (Client UX),
`docs/technical/workspace_folder_mutation_protocol.md` (Client + relocation semantics, with the D5 note),
`docs/technical/remote_device_control_threat_model.md` (no new authority class),
`docs/qa_maintenance/workspace_identity_relocation_qa.md` (remote Change Path rows).

## Security

- No new authority class. Workspace commands carry no narrower owner flag; an owner can already create,
  rename, and recursively delete folders inside the root from the cloud (`workspace_command_handler.dart`),
  so relocating a workspace record stays inside the authority Task 123 already ships (D1, study §4).
- Confinement is Agent-owned and unchanged: the target must resolve to an existing directory strictly inside
  `<SANAD_HOME>/workspaces`, with no link at any component, and never the root itself.
- The Client never assembles the target path: it returns a path the device itself reported in a
  `workspace_tree` reply, and the Agent revalidates it at preview and again at execution.
- The dialog stays folders-only and discloses nothing outside the root; the new copy reveals only that the
  root is the bound, which `list_workspaces` already implies.
- The preview ticket stays invisible to the user (D3); no token, fingerprint, or Home path is rendered.
- Out-of-root and in-root states are decided by the Agent's replies, not by Client-side path arithmetic.

## Live acceptance outline (coordinator-owned, two cloud Test Homes)

Never a same-device local-gateway-off shape; no `~/.sanad`, no port 58085. Outline: TH1 Client cloud-connected
to TH2 opens Settings → Workspace → Change Path, sees the in-app browser at the workspace's current folder,
picks a new folder, confirms the named target, and TH2's `list_workspaces` and a `pwd` tool call follow; an
over-the-cloud relocate to `/`, `$HOME`, the TH2 Home, `<root>/../x`, a NUL path, a symlink, and the root each
return `path_not_allowed` with the localized copy and no disk change; a second Client keeps the old path until
its next refresh (D5 evidence); Arabic pass of the CTA, notice, and out-of-root copy. The outline's D7 leg
was not executable with the available live tooling; see the record below.

## Live acceptance record (2026-10-24, two cloud Test Homes)

Executed by the coordinator on PR #331 (head `56248d80`) against `origin/main` `23b7a825`, the commit the
candidate branches from. Shape: **TH1's Client managing the TH2 device over the cloud** — never a
same-device local-gateway-off pair, no `~/.sanad`, no port 58085, and the third Test Home was untouched.

| | TH1 (observing Client) | TH2 (remote device) |
|---|---|---|
| Home | first Test Home | second Test Home |
| Worktree | `.agent/worktrees/test-home` | `.agent/worktrees/test-home-2` |
| Source | `56248d80` (candidate) | `23b7a825` (`origin/main`, Agent only) |
| Runtime | Agent + driver Client, cloud enabled | Agent only, cloud enabled |
| Device | "Sanad Agent Test (macOS)", `local=true` | "Sanad Agent Test2 (macOS)", `local=false` |
| Ownership | cross-owned 0, unverifiable 0 | cross-owned 0, unverifiable 0 |

TH2's Agent registered with the hosted gateway before the run (`Connecting…` → `Connected` →
`Registering Agent device` → `Successfully registered`) with no device authorization, credential prompt,
sign-in, or Keychain command. Because only the Client changed between the two checkouts, the Agent under
test is exactly the one the candidate assumes.

### Route proof — the cloud served every workspace command

TH2's `ServerSanadGatewayPlatform` received and executed `browse_workspace_tree`,
`workspace.create_folder`, `create_workspace`, `list_workspaces`, `workspace.get_policy`,
`workspace.relocate` (twice as preview → ticketed retry → `relocated`), and the step-5 refusal. TH1's
`LocalDaemonServerPlatform` served **zero** of
`browse_workspace_tree | workspace.create_folder | create_workspace | workspace.relocate` over its last
400 log entries and only TH1's own bootstrap commands (`get_sessions`, `get_session_history`,
`model.snapshot`, `get_appearance`), so nothing in this run resolved through TH1's local daemon. Both sides
reported the same `desktop/macos#MXSC66K8` device identity.

### Per-step verdicts

| # | Step | Verdict | Evidence |
|---|---|---|---|
| 1 | Register a workspace in TH2's root; Change Path opens the confined in-app browser | **PASS** | `workspace_change_path_button` present and enabled for the remote device; the tap produced `workspace_browser_new_folder_button`, `workspace_browser_parent_row`, `workspace_browser_cancel_button`, and `workspace_browser_use_folder_button` in the widget tree (no native panel); the browser opened at the workspace's current folder `<TH2 Home>/workspaces/acc-143/start` (D4); `workspace_browser_change_path_notice` showed the D2 scope sentence; the create-mode root hint was absent; the CTA read "Change to This Folder" |
| 2 | Change to `acc-143/target` with the D3 confirmation; TH2's record follows; nothing moves | **PASS** | the confirmation named `<TH2 Home>/workspaces/acc-143/target`; TH2 logged `workspace.relocate` → `workspace.relocate.preview` → `workspace.relocate` → `workspace.relocated`; the row kept its UUID and name with the new path and an advanced `updated_at`; reopening Change Path started at the new folder; `acc-143/start` still existed and no other folder moved or changed |
| 3 | Cancel paths send nothing | **PASS** | browser Cancel closed the dialog with no confirmation and only `browse_workspace_tree` on TH2; confirmation Cancel left the path unchanged and also sent no `workspace.relocate`; the run produced exactly one relocate pair, in step 2 |
| 4 | In-flight semantic (D5): the next turn runs in the new folder | **PASS** | one new conversation in the relocated workspace, one bounded `pwd` tool call, answer `<TH2 Home>/workspaces/acc-143/target`, executed by TH2 (`create_session` → `think` → `shell_execute`) |
| 5 | Out-of-root negatives (D7) | **PARTIAL** | the D7 matrix is not reachable live; every reachable negative was proven — see below |
| 6 | Local device unchanged (D8): native picker, no in-app browser | **PASS** with a recorded limitation | native branch taken, in-app browser not opened, nothing sent; the native panel itself is not observable — see below |
| 7 | Arabic pass (strings, RTL, LTR path line) | **PASS** | the localized Arabic notice, CTA, cancel, and confirmation title/buttons render; button order mirrors in both dialogs (RTL); the resolved path kept its explicit LTR block and its exact value; cancelling the Arabic confirmation left the path unchanged. `workspace_change_path_button` still reads "Change Path" in Arabic — the documented Task 95 leftover, not a Task 143 string |
| 8 | Cleanup and restore both Homes | **PASS** | the workspace was removed through Settings and `acc-143` deleted over the cloud; locale restored to English; both checkouts returned to `23b7a825` in their as-found run states (TH1 running one client, TH2 stopped); TH2's workspaces root matched its before-snapshot exactly and its `workspaces` rows were back to the original four |

The outline's "a second Client keeps the old path until its next refresh" leg was not executed; D5 is proven
by the next-turn `pwd` above, and the second-Client staleness stays covered by the existing
cache-reconciliation row in the QA page.

### Step 5 — why the D7 matrix is not reachable live

Three facts, each re-checked during the run:

| Fact | Evidence |
|---|---|
| No driver or CLI primitive can post a raw `workspace.relocate` | Client driver extensions are `inspect_ui`, `enter_text`, `scroll`, `tap`, `reveal`, `auth_url`; CLI actions are `snapshot`, `find`, `auth-url`, `tap`, `enter-text`, `scroll`, `wait-for`, `screenshot`, `batch` (tap, enter_text, scroll, wait_for, sleep, screenshot, snapshot, message_bodies). Nothing can carry an arbitrary command payload |
| The UI cannot select an out-of-root target by construction | managed listings skip links (`if (managed && entity is Link) continue;` in `workspace_file_system_coordinator.dart`), folder names are validated locally (`_isValidFolderName` rejects `.`, `..`, `/`, `\`, NUL), change mode has no path text field, and the root itself cannot be the target |
| A local relay is not a valid substitute | `relocateWorkspace(managedRemote: false)` takes `_normalizeExistingDirectory` instead of `requireManagedWorkspaceDirectory` (`local_workspace_runtime_service.dart:813-814`), so a local send to `/` would be **accepted**, not refused — it would neither exercise D7 nor be safe |

Proven live instead:

| Negative | Evidence |
|---|---|
| The root itself can never be sent | at `<TH2 Home>/workspaces` the CTA is `enabled:false` and only becomes `enabled:true` after entering a child folder |
| Browsing or picking outside the root is impossible | `workspace_browser_current_path` never left the root across three browser sessions; symlinks are filtered from managed listings; no path input exists; names with separators are rejected before any command is sent |
| A refusal is proven end to end over the cloud | picking another workspace's folder (`<TH2 Home>/workspaces/qa110-th1-cloud`) → confirm → toast `Failed to change workspace path: That folder is already connected to another workspace.`; TH2 logged `workspace.relocate` → `preview` → `workspace.relocate` → `device_event: error`, and the stored path was unchanged |

Coverage that stands in for the live matrix:

| Claim | Citation |
|---|---|
| Managed confinement rejects a NUL byte, a raw `..`, a relative path, an outside absolute path (including `$HOME`), the filesystem root, a registered workspace outside the root, and every link component, across the preview, relocate, browse, and create requests | `agent/test/interfaces/runtime/managed_workspace_confinement_test.dart:277` (group `security rejections`, S1–S6 and the link cases) |
| The cloud command handler maps those refusals to the coded `path_not_allowed` envelope, including the managed root itself | `agent/test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart:592`, `:606`, `:621`, `:638`, `:660` |
| `path_not_allowed` renders the D7 copy, and any other code keeps the daemon reason | `client/test/widget/settings/workspace_change_path_test.dart:358` (assertion at `:377`); mapping at `client/lib/features/settings/presentation/widgets/settings_pages/workspace_change_path.dart:117` |

Recorded honestly: the D7 toast copy was **not rendered in this run** and is automated evidence only. This is
a tooling gap, not a product defect — the refusals are Agent-owned and unit-covered, and every negative the
driver can reach (the root, a browsing escape, a cross-workspace target) was proven live.

### Step 6 — the native-picker branch (recorded limitation)

With the local device selected, one tap on Change Path for its workspace produced no `workspace_browser_*`
widget, no confirmation dialog, and no Flutter state change; the local Agent logged **zero**
`workspace.relocate` and the row kept its path. The branch taken is the intended one:
`client/lib/utils/workspace_picker_helper.dart` computes `isLocal = AppPlatform.isDesktop &&
device.isLocalReachable == true` → `getDirectoryPath(...)`, and the remote branch is unreachable there.

Not proven: that the native panel was displayed. A process sample of the Client after the tap showed the main
thread idle in `Dart_RunLoop` with no `runModal`/`NSOpenPanel` frame, so no modal was up at sampling time; the
driver cannot observe a native panel and no accessibility or window-server enumeration was used, because it
risks an OS prompt. The panel was never clicked and no pick was completed, so "the native path is taken and
the in-app browser is not used" is the proven statement.

### Merge and close-out

PR #331 merged to `main` as `50add1a3` (`feat(workspaces): 143 remote Change Path through the confined
browser (#331)`), carrying the Client change and the W5 documentation. This close-out is documentation only:
it records the live evidence, the step-5 and step-6 limits, the QA tooling notes in
[Workspace Identity and Change Path QA](../../qa_maintenance/workspace_identity_relocation_qa.md), and closes
the task frontmatter, gates, acceptance criteria, and DoD.

## Work split

| # | Item | Files | Size |
|---|---|---|---|
| W1 | Picker helper remote branch | `client/lib/utils/workspace_picker_helper.dart` | +35 |
| W2 | Dialog mode, CTA, notice, start folder | `workspace_browser_dialog.dart`, both ARB files | +60 |
| W3 | Settings wiring, gate, flow, D7 mapping | `settings_screen.dart`, `settings_pages/workspace_change_path.dart` | +90 |
| W4 | Tests | `client/test/**` | +300 |
| W5 | Docs and contracts | 6 pages | ~6 pages |

One writer round, one review, one coordinator-run live session. Size ratchet: no raised number, no new entry —
every touched file stays far below 1000 lines.

## Gates

### G1 — Task plan
- [x] This file committed on `feat/143-remote-change-path`.

### G2 — Picker and dialog (W1, W2)
- [x] `pickWorkspacePath` delegates to the confined browser for an online non-local device.
- [x] Change mode: CTA label, D2 notice, D4 start folder with a silent root fallback, root still disabled.
- [x] `fvm flutter gen-l10n` and `fvm flutter analyze` clean; dialog create-mode suite green.

### G3 — Settings wiring (W3)
- [x] Gate is `isOnline`; callbacks bound to the inspected device.
- [x] D3 confirmation names the resolved target; `path_not_allowed` renders the D7 copy.

### G4 — Tests (W4)
- [x] New Settings Change Path suite covers presence, binding, D4, cancel, send + ticketed retry, D7, and the
      local native-picker path.
- [x] Existing dialog, composer, sidebar, and schedules callers stay green; en/ar with an RTL pump.
- [x] `fvm flutter test test/guards/` green.

### G5 — Docs (W5)
- [x] The docs pages updated, with no stale "remote Change Path is a follow-up" or "local only" text left.
- [x] `fvm dart run scripts/lint_wiki.dart` from the repository root.

### G6 — Delivery
- [x] No `Co-Authored-By` or "Generated with" line anywhere.
- [x] PR opened to `main`; CI green.
- [x] PR #331 merged as `50add1a3`.

### G7 — Live acceptance and close-out
- [x] Two cloud Test Homes: TH1's Client managing the TH2 device over the cloud; every workspace command
      served by TH2's gateway and none by TH1's local daemon.
- [x] Steps 1–4 and 6–8 PASS; step 5 PARTIAL with the D7 matrix recorded as a live-tooling gap covered by
      Agent confinement tests and the Client D7 widget test; step 6's native panel recorded as not
      observable by the driver.
- [x] Both Homes restored, cleanup complete, and this file plus the QA tooling notes closed.

## Acceptance criteria

- [x] Given an online device reached over the cloud, when Settings → Workspace is opened, then Change Path is
      offered and opens the in-app browser rather than a native panel. — live, step 1.
- [x] Given the workspace's current folder is inside the root, when the browser opens, then it starts there;
      otherwise it starts at the root without an error. — live, step 1 (D4); the silent root fallback is
      widget-covered.
- [x] Given a chosen folder, when the CTA is pressed, then one confirmation names that folder before any
      command is sent, and the sent payload is exactly `workspace_id` + `new_path` (plus the invisible
      preview ticket on the retry). — live, steps 2–3 (single ticketed relocate pair, both cancels silent).
- [x] Given a target outside the root, when the Agent rejects it, then the D7 copy is shown and the workspace
      keeps its path. — automated evidence only: the live D7 matrix is unreachable (step 5 record); the D7
      copy and the refusal mapping are asserted by
      `client/test/widget/settings/workspace_change_path_test.dart:358` with the Agent refusals covered by
      `agent/test/interfaces/runtime/managed_workspace_confinement_test.dart:277`. Live, a cross-workspace
      refusal over the cloud kept the stored path and changed nothing on disk.
- [x] Given a same-desktop local device, then the native picker is used and the browser never opens. — live,
      step 6: the native branch is taken, no in-app browser opened, no relocate sent; the panel's display is
      not observable by the driver.
- [x] Automated coverage proves every item above without a live daemon. — 2365 Client tests (recorded
      counts below), with the Agent refusals covered by the existing confinement and handler suites. The live
      run adds transport proof over the cloud, not new assertions.

## Definition of Done

- [x] Analyzer clean; focused suites, guards, and one full Client fast suite green with recorded counts.
- [x] `fvm flutter gen-l10n` regenerated and committed; en/ar strings complete.
- [x] Owning `AGENTS.md` files and the documentation pages updated in this PR.
- [x] `graphify update .` run after the code change.
- [x] Live acceptance dispatched and executed by the coordinator on two cloud Test Homes; this task closes on
      that evidence — steps 1–4 and 6–8 PASS, step 5 PARTIAL and step 6's panel limitation recorded above,
      with the tooling gap and obstacles kept in
      [Workspace Identity and Change Path QA](../../qa_maintenance/workspace_identity_relocation_qa.md).

## Verification record (2026-10-24)

| Gate command | Result |
|---|---|
| `fvm flutter gen-l10n` (in `client/`) | exit 0 |
| `fvm flutter analyze` (in `client/`) | No issues found, exit 0 |
| `fvm flutter test test/widget/settings/workspace_change_path_test.dart test/widget/workspace_browser_dialog_test.dart` | 22 passed, exit 0 |
| `fvm flutter test test/unit/services/device_conversation_commands_test.dart test/widget/device_workspace_sidebar_structure_test.dart test/widget/schedules/schedule_editor_sheet_test.dart test/widget/conversation_input_panel_rebuild_test.dart` | 128 passed, exit 0 |
| `fvm flutter test test/guards/` | 6 passed, exit 0 |
| `fvm flutter test` (full Client fast suite) | 2365 passed, 3 skipped, exit 0 |
| `fvm dart run scripts/lint_wiki.dart` (repository root) | success, exit 0 |
| CI on PR #331 (`gh run watch 40053720642 --exit-status`) | client, bootstrap (macos/ubuntu/windows), docs/governance, branch history, protected labels: pass; `agent`, CLI, and release jobs skipped for unaffected paths |
| PR #331 merged | `50add1a3` on `main` |
| Live acceptance (two cloud Test Homes) | steps 1–4 and 6–8 PASS, step 5 PARTIAL, step 6 panel not observable; recorded above |

No Agent, protocol, or Gateway file changed. The close-out change itself is Markdown only and re-runs
`fvm dart run scripts/lint_wiki.dart` (SUCCESS).
