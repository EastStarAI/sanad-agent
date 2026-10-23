---
title: "Secrets Screen Live Acceptance"
description: "Live acceptance record for Settings → Privacy & Security → Secrets: the local scenario evidence at the shipped candidate, the code-inspected cloud parity decision, the canary scan, and the obstacles worth keeping for future testers."
---

# Secrets Screen Live Acceptance

> **Owning task:** `docs/plans/tasks/140-client-secrets-screen.md`
> **Protocol:** `docs/technical/secret_management_protocol.md`
> **Product UX:** `docs/product/settings_hub.md`

## Result

| Leg | Scope | Result |
|---|---|---|
| Local, one Test Home | Task 140 acceptance steps 1–9 | **PASS** — every step passed and every canary count was 0 |
| Cloud parity | Task 140 acceptance step 10 | **Verified by code inspection** (owner decision 2026-10-24) — see [below](#step-10--cloud-parity-verified-by-code-inspection) |

The local leg ran against candidate `8b0fb5d9` (`feat(secrets): 140-04 Privacy & Security secrets page and
dialogs`, PR #324), which merged to `main` as `2fed4227`. The results below are recorded against that
candidate; the close-out itself was written later and changes documentation only.

## Environment

| Item | Value |
|---|---|
| Candidate | `8b0fb5d9` (PR #324), merged as `2fed4227` |
| Test Home | a dedicated Test Home, never the primary `~/.sanad` |
| Runtime | `sanad-dev run all --driver --no-cloud --home <test-home> --background` |
| Managed routes | the Test Home's own agent (local gateway enabled) and one driver-enabled Client, both owned by that launcher |
| Canaries | two distinct fake 48-character values, kept outside the repository and typed only into the two value fields |
| Out dir | the delegate run's own out directory for logs, page dumps, and the WebSocket harness capture |

No canary value, no vault value, and no credential appears in this document or in any tracked file.

## Scenario evidence — local leg

Steps follow the numbering of the owning task. The original run report numbered the canary scan as step 9
and cleanup as step 10; the mapping is noted per row so both records agree.

| # | Scenario | Result | Evidence |
|---|---|---|---|
| 1 | Empty state on a Home with no secrets | **PASS** | `sidebar_general_settings_destination` → `nav_tile_privacy_security` → `secrets_page` rendered with `secrets_empty` ("No secrets stored"). No probe secret existed beforehand, so nothing had to be removed first. |
| 2 | Add `DATABASE_PASSWORD` with a canary value | **PASS** | `secrets_add_btn` → `secret_editor_dialog`; name `DATABASE_PASSWORD`, description `lt 140-04 probe`, canary A into `secret_value_input` → `secret_save_btn`; `secret_row_DATABASE_PASSWORD`, `secret_replace_btn_*`, and `secret_delete_btn_*` appeared. Read-only metadata read-back: `DATABASE_PASSWORD\|lt 140-04 probe\|user\|2026-10-23T20:02:04.755208Z` — the current date and `source=user`, i.e. M5 held. The 234-element page dump after the save contained **0** canary hits, so the value is not on the page. |
| 3 | The stored value resolves in a real turn | **PASS** | New conversation, one turn. The Agent called `system_list_secrets` (`{"secrets":["DATABASE_PASSWORD"],"count":1}`) then `shell_execute` with `secrets:["DATABASE_PASSWORD"]`; the permission card was approved once (`permission_option_once`). Stored tool result: `{"output": "      49\n", "duration_ms": 268449, "exit_code": 0}` — the command read 48 characters plus a newline, and the tool result carried **0** canary hits. Injection and the vault read path work end to end. |
| 4 | Replace the value; the old one never returns | **PASS** | `secret_replace_btn_DATABASE_PASSWORD` → dialog titled Replace: `secret_name_input` = `DATABASE_PASSWORD` with `readOnly: _isReplace`, `secret_value_input` **empty** (hint only, no pre-fill, no reveal control), `secret_replace_note` = "Replaces the saved value. The current value is never shown." Saved with canary B → `updated_at` advanced `20:02:04.755208Z` → `20:25:13.129570Z`. An echo turn (`echo $DATABASE_PASSWORD`, same `secrets` list, one approval) stored the tool result `{"output": "[REDACTED:DATABASE_PASSWORD]\n", "exit_code": 0}` — **the redaction marker `[REDACTED:DATABASE_PASSWORD]` replaced the new value in tool output**. Session history scan: 5 occurrences of that marker, **0** hits for canary A, **0** for canary B. |
| 5 | Delete with confirmation, then a refused turn | **PASS** | `secret_delete_btn_DATABASE_PASSWORD` → `secret_delete_dialog` ("Delete secret", `secret_delete_confirm_btn` = "Delete permanently", cancel present) → confirm → row gone, `secrets_empty` back, `user_secret_metadata` count 0. A later turn naming `DATABASE_PASSWORD` in `secrets` returned `{"isError": true, "output": "No stored secret named DATABASE_PASSWORD. Ask the user with system_request_secret first.", "duration_ms": 0}` with **tool error code `secret_not_found`**, and the assistant reported `terminal_reason: secret_not_found`. |
| 6 | Agent restart keeps the list, exposes no value | **PASS** | Re-added `DATABASE_PASSWORD` (canary A) → `sanad-dev restart agent` ("Daemon reached a safe restart checkpoint… restarted and healthy") → reopened Settings → Secrets: same row and same metadata (`DATABASE_PASSWORD\|lt 140-04 probe\|user\|2026-10-23T20:30:38.365182Z`), **0** canary hits in the page dump. No value is readable anywhere in the Client after the restart. |
| 7 | Canary scan after the whole run (run report: step 9) | **PASS** | Every target 0 — see [Canary scan](#canary-scan). |
| 8 | A second Client refreshes without a manual reload (run report: step 7) | **PASS** | One temporary harness (`agent/tool/secret_broadcast_probe.dart`, deleted after use): an authenticated local WebSocket, passive only, frames appended to the out dir; the Agent log confirmed "Active local clients: 2". With it listening, the UI Replace produced the frame `secrets.changed {"name":"DATABASE_PASSWORD","change":"set"}`; Delete produced `secrets.changed {"name":"DATABASE_PASSWORD","change":"deleted"}`; plus the initial `register_success`. The frame carries the keys **`change` and `name` only** — no value, prefix, or length field — with **0** canary hits. The UI list refreshed by itself after each mutation (row updated, then `secrets_empty`) with no manual reload. |
| 9 | Composer card secret appears in the list with the agent source (run report: step 8) | **PASS** | Turn: "I need you to store an API key named LT_140_04_AGENT. Request it from me with the secret request card." → `secret_request_card` with `secret_input_LT_140_04_AGENT` and `secret_request_save_btn` ("Save to vault"). Submitted canary B → metadata `LT_140_04_AGENT\|\|agent_request\|2026-10-23T20:35:19.087967Z` — `source=agent_request`, rendered as "Requested by the agent". `secret_row_LT_140_04_AGENT` was listed on the page, then deleted through the UI with confirmation (`secrets_empty`, metadata count 0). |

### Step 10 — cloud parity (verified by code inspection)

The task's step 10 asked for steps 1–9 repeated "over the cloud relay with the local daemon not directly
reachable". Owner decision 2026-10-24 replaces that with a code-inspection proof, because the configuration
the step described is not a supported product configuration: see
[`docs/technical/communication_protocols.md`](../technical/communication_protocols.md) §3.2 and
[`client/lib/features/devices/AGENTS.md`](../../client/lib/features/devices/AGENTS.md) (Client and Transport
Ownership). A real cloud live test runs on Test Homes configured for the cloud — two Agents and two Clients
connected through the cloud — never on a same-device pair with the local gateway switched off.

Cloud parity is therefore **verified by code inspection**: the feature has exactly one command path, it
routes through the shared device-command client and the connection coordinator, and nothing in the feature
can observe or select a transport.

| Claim | Citation |
|---|---|
| `SecretsClient` holds one `DeviceCommandClient` and nothing else transport-shaped | `client/lib/features/settings/data/secrets_client.dart:190` (class), `:193` (`final DeviceCommandClient _commands;`) |
| Every request goes through that client | `client/lib/features/settings/data/secrets_client.dart:310` (`_commands.request(...)`); broadcast reads at `:294` (`_commands.events(...)`) |
| That client resolves transport per call, entirely inside the coordinator | `client/lib/features/devices/data/device_command_client.dart:19` (class), `:26` (coordinator field), `:46` (`ensureConnectedEndpointForAgent` inside `request`), `:33` (same call inside `events`) |
| The route decision is the coordinator's local-reachability rule | `client/lib/features/devices/data/device_connection_coordinator.dart:183`–`185` (`resolve()` → `scope = localReachable ? local : cloud`), `:266`–`272` (`isLocalReachable` = desktop ∧ same hardware ∧ live local socket) |
| `SecretsCubit` never branches on connection scope | `client/lib/features/settings/presentation/bloc/secrets_cubit.dart:157`–`160` states the invariant; the file references no `ConnectionScope`, `isLocalReachable`, `preferred_connection_scope`, or cloud-socket symbol (verified by search: no matches) |
| The page builds one cubit from DI with the selected device only | `client/lib/features/settings/presentation/widgets/settings_pages/secrets_page.dart:37`, `:42`; the page, the editor dialog, and the delete dialog contain no transport symbol (verified by search: no matches) |

Because the command family, the projection, the error codes, and the strings are one shared path, a Client
that reaches a device over the cloud exercises the same code the local leg exercised. The local leg proves
the Agent side of that path against a real vault; the cloud leg would re-prove transport, which is already
covered by the cross-transport suites rather than by this screen.

## Canary scan

Every count must be 0. Counts are occurrences of either canary in a target, produced by
`grep -c -F -f <canary-file>` over the captured artifact; `state.db` was piped, never written to disk.

| Target | Scope of the capture | Count |
|---|---|---|
| Agent log | 4000 lines / 538 KB | **0** |
| Client log | 1492 lines / 167 KB | **0** |
| `request_dumps/` | recursive, 852 files | **0** |
| `state.db` | full dump, covering the whole conversation history | **0** |
| Harness frames | the step 8 capture, one JSON frame per line | **0** |
| Rendered Secrets page dumps | after the add, and after the restart | **0** / **0** |
| Post-cleanup re-scan | agent log, client log, `state.db` | **0** / **0** / **0** |

The scan covers the value directions the design promises: no model request, no tool result beyond the
redaction marker, no Client log, no socket frame, and no rendered page ever carried either canary.

## Obstacles worth keeping for future testers

1. **`sanad-dev run client --driver --no-cloud` is silently ignored while a managed runtime exists.** With a
   group already running, `handleRun` takes the "components are already running" branch and sends a
   component-control `start` to the existing launcher, which relaunches the Client from its *recorded*
   profile. The relaunched Client then carried `--dart-define=ENABLE_CLOUD_GATEWAY=true` and no
   `-t lib/driver_main.dart`, so `sanad-dev ui` answered "No active driver-enabled client is managed for
   this worktree" and the local-only leg was violated. Working sequence: `stop all --force` first, then
   launch the whole group once with the intended flags.
2. **A new conversation inherits the last-used model.** An inherited provider route whose credential fails
   latches a runtime notice, and the model picker only stages a next-message preference while that notice is
   latched, so selecting a model *after* the first failed send changes nothing. Working sequence: **new
   conversation → select the model → send**.
3. **`echo $SECRET` can be refused by the model on its own.** Re-issue the turn as an explicit acceptance
   instruction that names the value as a fake canary and states that redaction is under test. Nothing about
   the app was worked around; only the prompt changed.
4. **Every `shell_execute` needs a permission approval** under the default workspace policy. Approve once per
   turn with `permission_option_once`; never choose "always allow" for an acceptance run.
5. **Obscured value fields have no observable tree effect**, so `enter-text` into `secret_value_input` or
   `secret_input_<NAME>` needs `--no-verify`. The extension applies `updateEditingValue`, which replaces the
   whole text, so a retry cannot duplicate the value.
6. **The widget inspector hides un-keyed text inside a keyed row** (`walkKeyedChildren`). A row's
   description, updated date, and source pill are invisible to `snapshot`/`find --text`; verify them from the
   Agent metadata table with a read-only query plus the row keys, and dump the page for the canary check.
7. **`restart agent` leaves the recorded runtime source stale.** After a `git reset --hard`, the daemon
   restart succeeds while `status` still shows the old `Runtime source commit` and briefly reports
   `running (client only)`. It settles within seconds; a `stop all --force` plus `run all` refreshes the
   record to the new commit and leaves a matched pair.
8. **`sanad-dev restart client` can refuse** with "Client restart aborted: expected one verifiable running
   agent". Re-issue it once the Agent has settled; do not bypass the guard with a direct VM-service attach.
9. **Do not read a screenshot to verify a value.** A screenshot exists only as a visual record; canary and
   copy checks come from the page dump and the read-only metadata query.

## What a cloud live test needs

When a screen or command genuinely needs a cloud live leg, the supported shape is two Test Homes configured
for the cloud: one Agent and one Client per Home, both signed in, both devices present in the account, and
the command dispatched to the *remote* Home. The same-device relay-only configuration is not a supported
product configuration and is not a valid test setup — see
[`docs/technical/communication_protocols.md`](../technical/communication_protocols.md) §3.2.
