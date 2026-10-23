---
title: "Task 140 — Secrets Screen (Settings → Privacy & Security)"
description: "Give user secrets a real surface: a Settings → Privacy & Security page that lists each stored name with non-secret metadata, adds a value, replaces a value without ever reading the old one, and deletes with confirmation, over one local/cloud protocol path whose every value direction is write-only, model-invisible, and absent from logs, caches, and error text."
status: completed
current_gate: "closed — 140-01 merged (#315); 140-02 merged (#318); 140-03 merged (#323); 140-04 merged (#324); 140-05 live acceptance and close-out complete"
remaining_estimate: 0%
base_commit: 09d5c34a
depends_on: "138-11 (schema modules), 138-08 (bridge translator), 113b 113-01 (settings pages split) — see Work split"
---

# Task 140 — Secrets Screen (Settings → Privacy & Security)

## Goal

Let the user manage the secrets the Agent uses without going through the model: see what is stored,
add a value, replace a value, and delete one — with the value moving in exactly one direction, into the
vault, and never back out to any surface.

The screen closes the long-open item in Task 84 ("a Client Settings page to list and delete secrets
without the model") and extends it to add and replace, which Task 84 deliberately left out.

Scope: `agent/` (non-secret metadata, catalog, protocol) and `client/` (Settings destination, list,
add/replace/delete dialogs, strings). No change to the vault backend, the `custom:` namespace, the
injection rule, the echo redactor, the existing model tools, or the Full Access prompt rule (K8).

## Verified starting point (2026-10-23, `09d5c34a`)

| Fact | Evidence |
|---|---|
| User secrets live only in the vault's `custom:` namespace, keyed by name | `agent/lib/capabilities/secrets/user_secret_vault.dart` (`UserSecretVault`); `agent/lib/core/auth/secret_vault.dart` (`SecretVaults.custom`) |
| The vault can store, verify, list names, and delete — and nothing else | `UserSecretVault.store` (read-back verified), `names()`, `remove()`, `available`, `resolve()` |
| There is **no** description, created-at, updated-at, or source metadata for a stored secret | `UserSecretVault` has no metadata surface; the `custom:` index holds names only |
| Values are bounded and names are validated in one place | `UserSecretVault.maxValueLength = 16384`; `nameRejection` → `invalid_name` / `reserved_name` |
| The model has request/list/delete and can never supply a value | `agent/lib/capabilities/tools/system/secret_tools.dart` (`RequestSecretTool`, `ListSecretsTool`, `DeleteSecretTool`; owner-only, delete needs per-call approval) |
| No `secret.*` command exists in the gateway protocol | zero `secret.` entries in the accepted-command tables of `agent/lib/interfaces/platforms/sanad_gateway/protocol/canonical_command_translator.dart` |
| A whitelisted settings command family is the established pattern for a small owner-authorized mutation | `docs/technical/device_runtime_settings_protocol.md` (`device.settings.get` / `device.settings.update`, complete validation before one mutation, snapshot never carries a credential) |
| The Client has no secrets surface, and Settings has no Privacy & Security destination | 13 files under `client/lib/features/settings/`, none about secrets; `client/lib/features/settings/presentation/widgets/settings_navigation.dart` (`SettingsDestination`, 8 values) |
| The masked-input pattern already exists in the composer card | `client/lib/features/conversations/presentation/widgets/conversation_input/secret_request_card.dart` (masked fields, show/hide, en/ar, controllers cleared on submit) |
| Values are already excluded from command logs, client diagnostics, and relay storage | `docs/technical/remote_device_control_threat_model.md` §MCP payload handling (the Gateway does not persist or log `device_command` payloads); `client/lib/infrastructure/socket/socket_connection_controller.dart` `_isSensitiveLogKey` redacts `payload`, `content`, `secrets`, `secret`, `credential`, `password` |
| A central redactor exists for Agent-side strings | `agent/lib/core/secrets_redactor.dart` |
| User-secret semantics are owned by one design section | `docs/technical/execution_trust_and_permission_authority.md` §10 |
| The state database is allowlisted at 1,635 lines and 138-11 is splitting its schema | `agent/test/guards/file_size_ratchet_guard_test.dart`; `docs/plans/tasks/138-agent-srp-tier2.md` item 138-11 |
| The Settings pages host is allowlisted at 2,018 lines and 113b 113-01 is splitting it | `client/test/guards/file_size_ratchet_guard_test.dart`; `docs/plans/tasks/113b-srp-tier2-client-presentation.md` item 113-01 |

## Binding decisions

Fixed by the product owner; not reopened here.

| # | Decision | Source |
|---|---|---|
| K1 | The screen lives at **Settings → Privacy & Security**. | accepted recommendation |
| K2 | The list shows **name, description, and updated date**. | accepted recommendation |
| K3 | The user can **add** a value and **replace** a value. Replacing never shows the old value. | U3 |
| K4 | There is **no reveal**, ever — not for the user, not for the model, not for support. | U3 |
| K5 | **Delete** is available with a confirmation. | accepted recommendation |
| K6 | The list contains **only the user's own secrets** (`custom:`); provider and MCP credentials keep their own screens and never appear here. | accepted recommendation |
| K7 | Both screens behave identically over local and cloud connections. No local-only restrictions. | U4 |
| K8 | The Full Access rule for commands that name secrets is **unchanged**: a Full Access turn does not prompt for them (standing Plan 83/84 decision), and this page does not restate the policy. | owner decision 2026-10-23 |
| K9 | Backend logging of `secret.set` is verified, with no block on this task: the private Backend logs the command name only, never the payload, and its socket.io server logger is disabled. | owner decision 2026-10-23 |

### Amendments this task records

| Law | Before | After |
|---|---|---|
| Task 84 §4 out-of-scope ("a Client Settings page to manage secrets — proposed, needs a scope decision") | out of scope | in scope (K1–K6) |
| `docs/technical/execution_trust_and_permission_authority.md` §10 "Listing, deletion and revocation" | names only, delete through the model tool | additionally a user-authority list with non-secret metadata, plus user-authority add/replace/delete; the model's tools are unchanged |
| A2, first bullet ("a name with no metadata row is returned with `description: null` and `updated_at: null`") | projected nulls for an unrepaired name | `updated_at` is NOT NULL, so a null could not also be repaired. Owner decision 2026-10-23: `list()` repairs in the same read — it inserts `source = agent_request`, `description = NULL`, `created_at = updated_at = now` — so a returned entry never carries a null timestamp. The repair records `agent_request` because that was the only arrival path before this screen existed, so it never claims the user typed the value |
| A2, `set(name, value, description)` description semantics | unstated | the passed description is authoritative: `null` or a whitespace-only string clears the column. The Replace dialog always submits the full desired description |
| 140-01 Work split file locks | owner classes and tests only | plus minimal wiring, owner decision 2026-10-23: `evolution/db/agent_state_database.dart` (one `UserSecretsSchema.apply` call at the pinned end position) and `core/di.dart` (repository and catalog registration, `SecretAcquisition` metadata injection). Wiring only, no logic |
| Live acceptance step 10 ("repeat 1–9 over the cloud relay with the local daemon not directly reachable") | a same-device relay-only live leg as the cloud proof | **verified by code inspection**, owner decision 2026-10-24: `SecretsClient` reaches the device only through `DeviceCommandClient` → `DeviceConnectionCoordinator`, and neither `SecretsCubit` nor the page branches on connection scope, so cloud parity is structural. Recorded with file:line citations in `docs/qa_maintenance/secrets_screen_acceptance.md` |
| Same-device connection routing | unstated | **supported configurations are local only, and local + cloud**; a same-device Agent and Client reached only through the cloud relay with the Agent's local gateway off is not supported, not a default, and not a user option, and Client behavior in that shape is not a defect to fix (owner decision 2026-10-24). Recorded in `docs/technical/communication_protocols.md` §3.2 and `client/lib/features/devices/AGENTS.md` |
| A real cloud live test shape | one Test Home, local gateway off | **two Test Homes configured for the cloud**: two Agents and two Clients connected through the cloud, commands dispatched to the remote Home. The same-device local-gateway-off recipe is removed from the Client Tester connection-switching reference (owner decision 2026-10-24) |

### Design decisions taken to make the fixed decisions executable

Not product choices; they exist because the fixed decisions do not name a shape.

| # | Decision |
|---|---|
| M1 | **Values stay in the vault; metadata stays in the database.** A new non-secret table `user_secret_metadata` (name PK, description, source, created_at, updated_at) owns the three displayed fields. No value, no hash of a value, and no value prefix ever enters it. |
| M2 | One new Agent owner, `UserSecretCatalog` (`agent/lib/capabilities/secrets/user_secret_catalog.dart`), joins vault names with metadata rows, prunes metadata whose name no longer exists in the vault, and is the only reader the protocol handler uses. |
| M3 | Write ordering: vault first (verified), metadata second. A verified vault write is never reported as a failure because metadata could not be written; the row is repaired on the next catalog read. Metadata is never written for a value the vault refused. |
| M4 | The protocol is write-only: `secrets.list` returns metadata, `secret.set` returns metadata, `secret.delete` returns an outcome. No command, response, event, or error carries a stored value in any direction. |
| M5 | `source` records how the **current** value arrived: `agent_request` when it came through the Task 84 acquisition card, `user` when it came through this screen. A replacement through the screen sets it to `user`. |
| M6 | The submitted value is rejected if it is a redaction sentinel (`[REDACTED:…]`) or empty, so a displayed mask can never be written back as a secret. |
| M7 | New owners keep the ratchet green: `capabilities/secrets/user_secret_catalog.dart`, `evolution/db/user_secret_metadata_repository.dart`, `interfaces/platforms/sanad_gateway/handlers/secret_command_handler.dart`, `client/lib/features/settings/presentation/widgets/settings_pages/secrets_page.dart` + its dialogs. `agent_state_database.dart` (1,635) may not grow, and no `settings_pages/` library takes a new ratchet entry. |

## Agent work

### A1 — Non-secret metadata

- New table `user_secret_metadata` in the schema module that 138-11 establishes for it
  (`agent/lib/evolution/db/schema/user_secrets_schema.dart`), through the existing guarded,
  idempotent migration. Before 138-11 this item does not start: the DDL lives in an allowlisted
  1,635-line file and may not grow.

| Column | Type | Notes |
|---|---|---|
| `name` | `TEXT` PK | the vault name; the only identity |
| `description` | `TEXT` NULL | user-authored, bounded (256 characters), never derived from a value |
| `source` | `TEXT` NOT NULL | `agent_request` \| `user` (M5) |
| `created_at` | `TEXT` NOT NULL | ISO-8601 UTC |
| `updated_at` | `TEXT` NOT NULL | ISO-8601 UTC; advances on every replacement |

- `UserSecretMetadataRepository` owns every read/write of that table; no other owner touches it.
- Rows are created by the acquisition path (Task 84) with `source='agent_request'` when a value is
  stored there, and by this task's command with `source='user'`.

### A2 — Catalog

`UserSecretCatalog` is the single read model behind the screen:

- `list()` → one entry per name present in `vault.names()`, joined with its metadata row. The vault
  exposes names only (no timestamps), so a name with no metadata row is returned with
  `description: null` and `updated_at: null`; metadata rows for names the vault no longer holds are
  pruned on read.
- `set(name, value, description)` → validates the name (`nameRejection`), the value (non-empty, at most
  `UserSecretVault.maxValueLength`, not a redaction sentinel), calls `vault.store({name: value})`, then
  upserts metadata with `source='user'` and `updated_at=now` (M3).
- `delete(name)` → `vault.remove([name])` then deletes the metadata row; reports `deleted` or
  `not_found`.
- **The catalog never calls `UserSecretVault.resolve`.** A guard test fails if a value-reading call
  appears on any path reachable from the protocol handler.
- Vault unavailability is a typed outcome (`vault_unavailable`), never a silent success: the existing
  `available` check gates the whole command before any metadata write.

### A3 — Acquisition-path metadata

Task 84's `SecretAcquisition` writes values into the vault from the composer card. It gains one call to
the metadata repository so a card-stored secret appears in the list with `source='agent_request'`.
Nothing else about the acquisition path changes: no value leaves it, and `resolved_decision` stays
value-free.

### A4 — Documentation

`docs/technical/agent_database_schema.md` (new table), `docs/technical/execution_trust_and_permission_authority.md`
§10 (the new listing/add/replace/delete authority, and that the model tools are unchanged),
`docs/product/settings_hub.md` (the Privacy & Security destination), `agent/lib/capabilities/AGENTS.md`
where the secrets ownership statement becomes stale.

## Protocol

One code path for local and cloud (K7). Commands travel in the existing `device_command` envelope and
resolve transport per request in `DeviceConnectionCoordinator`. The handler receives its dependencies
as constructor inputs and never resolves runtime owners through `getIt`.

### Commands

| Command | Response | Payload (request → response) |
|---|---|---|
| `secrets.list` | `secrets.list_result` | `{}` → `{secrets:[…], truncated:false}` |
| `secret.set` | `secret.saved` | `{name, value, description?}` → `{name, description, source, created_at, updated_at}` |
| `secret.delete` | `secret.deleted` | `{name, confirm:true}` → `{name, status:'deleted'\|'not_found'}` |

List projection — **structurally value-free**:

```json
{
  "secrets": [
    {
      "name": "DATABASE_PASSWORD",
      "description": "Staging database password",
      "source": "user",
      "created_at": "2026-10-23T08:12:00Z",
      "updated_at": "2026-10-23T09:40:11Z"
    }
  ],
  "truncated": false
}
```

- `value` appears exactly once in the whole protocol: in the `secret.set` request. It is absent from
  every response, every event, and every error, and it is never logged.
- `secrets.changed` (`{name, change: 'set'|'deleted'}`) is broadcast to every Sanad client on every
  platform after a successful mutation, so a second client refreshes instead of showing a stale row.
  The event carries the name and the change only.
- Requests are validated completely before the first mutation: unknown fields, a wrong type, a
  `description` over 256 characters, or a missing `confirm` on delete mutate nothing.

### Error codes

| Code | When |
|---|---|
| `invalid_request` | unknown field, wrong type, missing `name`, missing `confirm` on delete |
| `invalid_secret_name` | `nameRejection` returned `invalid_name` |
| `reserved_secret_name` | `nameRejection` returned `reserved_name` (protected operator variable or a Sanad credential) |
| `invalid_secret_value` | empty value, a value over `maxValueLength`, or a redaction sentinel (M6) |
| `vault_unavailable` | the platform vault cannot store now; nothing written |
| `internal_error` | repository failure; nothing mutated |

Error envelopes keep the existing shape (`{type:"error", payload:{request_id, code, message}}`). The
`message` names the secret and the reason and **never** contains the submitted value, a prefix of it,
or its length in characters.

## Client work

### C1 — Entry point

- New `SettingsDestination.privacySecurity` and a **Privacy & Security** group inside the **selected
  device** section of `settings_navigation.dart` (next to Overview, Providers, MCP Servers, and Skills),
  containing the **Secrets** destination. A secret lives in one device's Home vault, so the page is
  device-scoped like Providers and Skills.
- `SettingsSecretsPage` in `client/lib/features/settings/presentation/widgets/settings_pages/`
  (a new file in the folder 113b 113-01 created; no settings page library takes a ratchet entry).
- The route stays inside the existing Settings destination (`/settings?section=privacySecurity`), so no
  new top-level route is needed.

### C2 — Screens and dialogs

- **List.** One row per secret: name, description (or a "No description" placeholder), the updated
  date rendered in the client locale, a source chip (Added by you / Requested by the agent), and the
  row actions Replace and Delete.
- **Add.** A dialog with name, description (optional), and a masked value field with a show/hide
  toggle, plus Save. The name is validated against the same rules the Agent enforces, so the user sees
  the reason before the request leaves the client.
- **Replace.** The same dialog with the name read-only, the description editable, the value field
  **empty**, and the note "Replaces the saved value. The current value is never shown." No pre-fill, no
  preview, no reveal control (K3, K4).
- **Delete.** A confirmation dialog naming the secret and stating that the deletion is permanent, then
  the command with `confirm:true`.
- Masked-field behavior follows the existing composer card (obscured text, no suggestions or
  autocorrect, show/hide toggle, controllers cleared on submit and on cancel). If the card's field can
  be lifted into a shared `MaskedSecretField` without touching the timeline, do that; otherwise keep
  the new field local to the settings feature and leave the card alone.
- No policy copy: the page states only what is stored and that values are write-only. It does not
  restate the Full Access prompt rule, which is unchanged (K8).

### C3 — States

| State | Presentation |
|---|---|
| loading | page skeleton; no request from `build` (Render and Request Independence) |
| empty | "No secrets stored" + the Add action |
| error | typed message from `DeviceCommandException.code` in localized copy, plus Retry |
| device unavailable | "Unavailable" banner, actions disabled, no stale list presented as current. `DeviceConfig.isOnline == false` short-circuits before any request |
| loaded | list + actions; `secrets.changed` refreshes through the owning cubit |

One cubit for the feature; dialog-local form state stays in the dialog, and the submitted value never
enters the cubit.

### C4 — Strings

Every user-facing string is authored in `client/lib/l10n/app_en.arb` and translated in `app_ar.arb`;
no Arabic literal in handwritten Dart. At minimum: `privacyAndSecurity`, `secrets`, `secretsEmpty`,
`addSecret`, `secretName`, `secretDescription`, `secretDescriptionOptional`, `secretValue`,
`secretValueHint`, `secretValueShow`, `secretValueHide`, `saveSecret`, `replaceSecret`,
`replaceSecretNote`, `deleteSecret`, `deleteSecretConfirm`, `secretDeleted`, `secretSaved`,
`secretUpdatedAt`, `secretSourceUser`, `secretSourceAgent`, `secretNoDescription`,
`secretInvalidName`, `secretReservedName`, `secretValueRequired`, `secretValueTooLong`,
`secretsUnavailable`, `secretsLoadFailed`, `secretsSaveFailed`, `retry`.

### C5 — Local and cloud

The page and every action use `DeviceCommandClient` → `DeviceConnectionCoordinator`. No screen selects a
transport or branches on connection scope (K7). The same cubit, states, and strings serve both routes,
including web and mobile, which are cloud-only and therefore reach the same commands.

## Security

### No value is ever returned or logged

- **Structurally absent.** The list projection has no value field, so no code path can accidentally
  include one; `secret.set` returns metadata; `secret.delete` returns an outcome. There is no
  `secret.get` and no reveal command to add later without a new decision.
- **Agent logging.** The handler and the catalog log the secret **name** and the outcome only. They
  never log the request map, never call `toString()` on it, and never interpolate the value into an
  exception. `agent/lib/core/secrets_redactor.dart` remains the single scrubber for any string that
  could reach a log or a runtime notice, and a test asserts a captured log for a `secret.set` contains
  the name and not the value.
- **Error text.** Every failure path is typed before it is formatted; a `FormatException` from value
  validation is mapped to `invalid_secret_value` and never echoes the input. A test submits a
  distinctive canary value through every failing path and asserts zero occurrences in the response,
  the logs, and `request_dumps/`.
- **Model context.** The value never enters a model turn: it is not a tool argument, not a tool result,
  not a history row, and not part of the LLM request, so request dumps and compaction cannot carry it.
  The model's tools are unchanged — it still cannot write a value it supplies (Task 84), and
  `system_list_secrets` still returns names only, so this screen grants the model nothing.
- **Client.** The value lives only in the dialog's text controller, is cleared on submit and on cancel,
  and never enters cubit state, the conversation cache, `SharedPreferences`, the timeline, or a log.
  Socket diagnostics already redact `payload` and `content` wholesale, so a debug log of the command
  shows `[REDACTED]` where the payload was.
- **Replace semantics.** Write-only: the form starts empty, no surface can read the old value, and a
  submitted redaction sentinel is rejected on both sides (M6) so a displayed mask cannot become a
  stored secret. Replacing is the only rotation path, and it is a single verified vault write.
- **Deletion.** `confirm:true` is required and the Client asks first; the vault entry and its metadata
  row go together. A command already running keeps the environment it started with (Task 84), and a
  later command naming the deleted secret fails `secret_not_found`.

### How the value travels over the cloud relay

1. The Client sends `secret.set` inside the authenticated `device_command` envelope on its Cloud
   Socket (WSS). The value is in the payload body — never in a URL, query string, or header — so an
   access log cannot capture it.
2. The Gateway authenticates the app socket, proves the user owns the target device, and relays the
   command to that device's live daemon connection. It **does not persist the payload and does not log
   it** (the existing rule for `device_command` in
   `docs/technical/remote_device_control_threat_model.md`); it records the command name and device id
   only. `secret.set` is verified against that rule: the private Backend logs the command name only,
   never the payload, and its socket.io server logger is disabled (K9). Nothing about a secret becomes
   hosted settings.
3. The daemon receives the command on the same handler the local route uses, validates it, and writes
   the value to the per-Home OS vault (`custom:`). The value is never written to the agent-state
   database, a workspace file, `.env`, or a dump.
4. The response carries metadata only, and the relay returns it to the requesting socket. The broadcast
   `secrets.changed` carries a name and a change, never a value.

If any step above cannot be honored, the item does not ship: the value direction is the whole point.

### Redaction summary

| Surface | Guarantee |
|---|---|
| Gateway | payload not persisted, not logged (verified for `secret.set`, K9) |
| Agent logs | name and outcome only; `SecretsRedactor` for any free text |
| Agent errors | typed code plus a message that never contains the value |
| Request dumps / history / compaction | the value never enters a model request |
| Client state / cache / prefs | never stored; controller cleared on submit and cancel |
| Client socket diagnostics | `payload`/`content`/`secrets` keys already redacted |
| `secrets.changed` | name plus change only |

## Tests and Definition of Done

### Agent

- Unit: `user_secret_metadata` migration on a fresh and a current database, idempotent on a second run.
- Unit: catalog joins names with metadata, returns a name with no row, and prunes an orphan row on read;
  `list` returns no value and no value-derived field.
- Unit: `set` validates name, value, length, and sentinel; a verified vault write followed by a metadata
  failure still reports success (M3) and the next read repairs the row; a refused vault write leaves no
  metadata row.
- Unit: replace advances `updated_at` and sets `source='user'`; delete removes both rows and reports
  `not_found` for an unknown name.
- Guard: no path reachable from the protocol handler calls `UserSecretVault.resolve`; the handler module
  does not reference `resolve` at all.
- Handler: every command's success path; each error code; unknown-field and oversized-description
  rejection mutating nothing; `secrets.changed` broadcast; the response envelope for a canary value
  contains no fragment of it.
- Security: a captured log, a captured error, and a `request_dumps/` scan after a `set` contain zero
  occurrences of the canary value.
- Regression: Task 84's suites stay green (owner-only tools, per-call delete approval, injection, echo
  redaction, acquisition card).

### Client

- Cubit: load/empty/error/unavailable states, no fetch from `build` or a rebuild, `secrets.changed`
  refresh, single-flight per action.
- Widget: list renders name/description/date/source; empty and unavailable states; Add validates the
  name and a non-empty value; Replace opens with an empty value field and no reveal control; Delete
  asks for confirmation; the controller is empty after submit and after cancel; a state snapshot taken
  after submit contains no value.
- Localization: every new key exists in `en` and `ar`; no hard-coded English copy; an RTL pass on the
  list and both dialogs.
- Guards: both size-ratchet guards stay green, no raised number, no dead entry.

### Live acceptance (one Test Home; step 10 amended to a code-inspection proof)

Scenario steps 1–9 run once on one Test Home. Step 10 was amended by owner decision 2026-10-24: cloud
parity is verified by code inspection instead of a same-device relay-only live leg, because that
configuration is not supported. The pass evidence for every step is recorded in
[`docs/qa_maintenance/secrets_screen_acceptance.md`](../../qa_maintenance/secrets_screen_acceptance.md).

1. Empty state: the page shows "No secrets stored" on a Home with none.
2. Add `DATABASE_PASSWORD` with a canary value: the row appears with the description and the current
   updated date; the value is nowhere on the page.
3. The value works: an agent command naming it in `shell_execute.secrets` succeeds, and the canary is
   redacted in the tool output.
4. Replace the value: the row's updated date advances, the field starts empty, and a command that
   prints the value shows the **new** value redacted and never the old one.
5. Delete with confirmation: the row disappears; a later command naming it fails `secret_not_found`.
6. Restart the daemon: the list is identical and no value is readable anywhere in the Client.
7. Canary scan after the whole run: zero occurrences in the agent log, the client log, `request_dumps/`,
   `state.db`, and the conversation history.
8. A second Client connected to the same device refreshes the list after each mutation without a manual
   reload.
9. A secret stored through the composer card (Task 84) appears in the list with the "Requested by the
   agent" source.
10. Cloud parity: **verified by code inspection** (owner decision 2026-10-24). `SecretsClient` sends only
    through `DeviceCommandClient`, which resolves transport per request inside
    `DeviceConnectionCoordinator`, and neither `SecretsCubit` nor the page branches on connection scope
    (K7, C5). Citations are recorded in the acceptance document. A live cloud leg, when one is needed,
    runs on two Test Homes configured for the cloud — never on a same-device pair with the local
    gateway turned off.

### Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5` and
      `cd client && set -o pipefail; fvm flutter analyze 2>&1 | tail -5` are clean — clean at every merged
      candidate (`234c770c`, `1874cdb9`, `98e721c0`, and the 140-04 candidate).
- [x] Focused suites per item, then the full fast suite of each package on the frozen candidate, reporting
      command, exit code, counts, duration, and a bounded final-five-line summary — Agent full fast suite
      3848 passed / 16 pre-existing skips; Client full fast suite 2209 passed / 3 skipped (3m27s); focused
      counts per gate below.
- [x] Daemon-backed E2E for the new command family (a real socket round trip), because the value direction
      is a system boundary that mocks cannot prove; local and cloud acceptance per the list above — local
      acceptance steps 1–9 PASS against a real Home vault, with a real Agent restart and a real broadcast
      frame. Cloud parity is the code-inspection proof recorded as step 10 (owner decision 2026-10-24); no
      cloud E2E ran, and the relay-only same-device shape it would have required is not a supported
      configuration. Evidence: `docs/qa_maintenance/secrets_screen_acceptance.md`.
- [x] Documentation updated in the same change: schema, the trust/authority section, the product settings
      page, and the new protocol page. No stale "needs a scope decision" statement survives — plus this
      close-out's acceptance document, the settings hub correction, and the §3.2 routing decision.
- [x] `graphify update .` after the code change — run for each gate's code change.
- [x] Size ratchet green — no raised number and no new `settings_pages/` entry; guards green in every gate.

## Work split

Ordered, with the file locks each item holds while its PR is open. Do not start an item whose lock is
held by an open SRP PR; merge that PR first (138 decision 8: no rebase across a lock).

| Item | Wave | Files locked | Blocked by |
|---|---|---|---|
| 140-01 metadata table + repository + catalog + acquisition hook | 1 | `agent/lib/evolution/db/schema/user_secrets_schema.dart`, `evolution/db/user_secret_metadata_repository.dart`, `capabilities/secrets/user_secret_catalog.dart`, `capabilities/secrets/secret_acquisition.dart`, `agent/test/capabilities/**`, `docs/technical/agent_database_schema.md`, `agent/test/guards/file_size_ratchet_guard_test.dart` | **138-11** (the DDL host); **138-05** snapshot fixtures may need a new entry |
| 140-02 protocol: commands, handler, broadcast, tests | 2 | `agent/lib/interfaces/platforms/sanad_gateway/handlers/secret_command_handler.dart`, `protocol/canonical_events.dart`, `agent/test/interfaces/platforms/sanad_gateway/**`, `docs/technical/secret_management_protocol.md`, `docs/technical/communication_protocols.md`, `docs/technical/execution_trust_and_permission_authority.md` | **138-08** (dispatch table) and 140-01 |
| 140-03 Client data + cubit | 3 | `client/lib/features/settings/data/secrets_client.dart`, `features/settings/presentation/bloc/secrets_cubit.dart` (or the feature-local equivalent), `client/test/**secrets*` | 140-02 |
| 140-04 Client destination + page + dialogs | 4 | `client/lib/features/settings/presentation/widgets/settings_navigation.dart`, `settings_screen.dart`, `settings_pages/secrets_page.dart`, `settings_pages/secret_editor_dialog.dart`, `settings_pages/delete_secret_dialog.dart`, `client/lib/l10n/app_{en,ar}.arb` | **113b 113-01** (landed: `settings_pages/` and `settings_screen.dart` fan-in) and 140-03. The new page is its own file under `settings_pages/` |
| 140-05 live acceptance + close-out | 5 | this file, `docs/qa_maintenance/secrets_screen_acceptance.md`, `docs/product/settings_hub.md` | 140-04 |

- 140-01/140-02 are Agent-only; 140-03/140-04 are Client; 140-05 is QA. Never run Agent and Client
  suites concurrently on one machine.
- Hard SRP dependencies: **138-11** (schema host) and **138-08** (bridge switch) on the Agent,
  **113b 113-01** (settings pages host) on the Client. No other SRP item owns a file this task needs.
- 113b 113-01 has landed: `settings_pages/` exists, so 140-04 only adds files plus the two
  navigation edits. Never move the new page back into a shared page library or add a ratchet entry.

## Gate progress

### 140-01 — metadata table + repository + catalog + acquisition hook — merged

- [x] A1 `user_secret_metadata` in `evolution/db/schema/user_secrets_schema.dart`, applied after every
      pre-existing module; additive and idempotent for an existing Home.
- [x] A1 `UserSecretMetadataRepository` owns every read and write of the table.
- [x] A2 `UserSecretCatalog`: `list` (join, repair-on-read, prune), `set`, `delete`, and the value
      rules; it never calls `UserSecretVault.resolve`.
- [x] A3 `SecretAcquisition` records `source = agent_request` for every name a Task 84 card stored.
- [x] A4 documentation: schema §3.6 and §10, trust/authority §10, product settings hub,
      the capabilities and evolution-db contracts.
- [x] Tests: migration (fresh, existing Home, three idempotent opens, no value-shaped column),
      catalog (join/repair/prune, validation, M3 ordering, replace/delete, log and dump scans),
      acquisition hook, and the value-read guard.
- [x] Schema snapshots regenerated for all four fixtures: one new table each, no other movement.
- [x] Merge (merged as PR #315, commit `06f99a37`).

Verification at commit `234c770c` (PR #315): `fvm dart analyze` clean; 6 migration + 26 catalog +
8 acquisition + 7 guard tests; `test/evolution/` 456 passed; guard suite 18 passed; Task 84
regression 74 passed; full Agent fast suite 3848 passed / 16 pre-existing skips; `lint_wiki.dart`
clean; `graphify update` run. All required CI checks pass.

### 140-02 — protocol: commands, handler, broadcast, tests — merged

- [x] Wire commands translated and dispatched: `secrets.list`, `secret.set`, `secret.delete` in `canonical_command_translator.dart` and `sanad_protocol_bridge.dart`.
- [x] `SecretCommandHandler` implemented: write-only, structurally value-free list projection, add/replace rotation, confirmed deletion, typed outcomes.
- [x] Security: no secret value ever returned or logged; sentinel canary tested against logs, responses, broadcasts, error envelopes, and request dumps.
- [x] Authority: device-owner only (`command_authority: owner`); unverified callers refused with `permission_denied` mutating nothing.
- [x] Family broadcast: `secrets.changed` with `{name, change: 'set'|'deleted'}` published to all Sanad client platforms via `publishFamilyEvent`.
- [x] Static guard: `secrets_value_read_guard_test.dart` asserts `secret_command_handler.dart` contains no `.resolve(` or `.read(` calls and references `resolve` nowhere.
- [x] Documentation: `secret_management_protocol.md`, `communication_protocols.md`, `execution_trust_and_permission_authority.md`.
- [x] Tests: unit tests for `SecretCommandHandler` (28 tests), `CanonicalCommandTranslator` (4 tests), guards (20 tests), Task 84 regression (81 tests), and evolution suite (456 tests).
- [x] Merge (merged as PR #318, commit `1874cdb9`).

### 140-03 — Client data + cubit — merged

- [x] `SecretsClient` (`client/lib/features/settings/data/secrets_client.dart`): `secrets.list` / `secret.set` /
      `secret.delete` through `DeviceCommandClient`, the value-free `StoredSecret` projection, a payload-free
      `secrets.changed` signal, and the value rules mirrored from the Agent (empty, `maxValueLength`, redaction
      sentinel).
- [x] Typed errors: `SecretsErrorCode.fromWireCode` maps every protocol code (plus an unmapped code and a
      transport failure) and no Agent `message` text is carried into a Client value.
- [x] `SecretsCubit` (`presentation/bloc/secrets_cubit.dart`): the C3 states, no fetch on construction or from
      `build`, `DeviceConfig.isOnline == false` short circuit, `secrets.changed` re-read that never trusts the
      payload, coalesced `load`, and `busy` for a second in-flight mutation. Local and cloud share the one path
      (C5).
- [x] The submitted value is a method argument that is sent and dropped: no cubit or state field, no cache, no
      log line, no exception text. Tests assert a canary value is absent from every emitted state after both a
      successful and a failed set.
- [x] `delete` always sends `confirm: true`; the confirmation dialog stays in 140-04.
- [x] `SecretsClient` registered in `core/di/injection.dart` next to the other device command clients.
- [x] Documentation: `docs/technical/secret_management_protocol.md` §8 (client contract, state table, error
      mapping, admission) and `client/lib/features/settings/AGENTS.md` (Privacy and Security Secrets).
- [x] Tests: `secrets_client_test.dart` (21) and `secrets_cubit_test.dart` (27) — 48 focused tests.
- [x] Verification: `fvm flutter analyze` clean; focused 48 passed; `test/guards/` 3 passed; full Client fast
      suite 2183 passed / 3 skipped; `lint_wiki.dart` clean.
- [x] Merge (merged as PR #323, commit `98e721c0`).

### 140-04 — Client destination + page + dialogs — merged

- [x] C1 `SettingsDestination.privacySecurity` and a Privacy & Security group in the selected-device
      section of `settings_navigation.dart`, holding Secrets. The route stays
      `/settings?section=privacySecurity`; no new top-level route.
- [x] C2 `settings_pages/secrets_page.dart` (`SettingsSecretsPage`), `secret_editor_dialog.dart` (Add and
      Replace), `delete_secret_dialog.dart`, and the shared typed-failure copy in
      `secrets_failure_text.dart`. The composer card is unchanged: its field stays local to the Task 84
      request flow because lifting it would need the request-field spec, the card's keys, its border color
      and its fonts, and `conversation_input/secret_request_card.dart` is outside this item's file locks.
- [x] One `SecretsCubit` per page, created from DI with the selected device; `load()` from `initState` and
      from Retry only, never from `build`.
- [x] C3 loading, empty, error with Retry, device unavailable, and loaded. Going offline drops the list and
      disables the actions; an online device whose transport failed also offers Retry in the banner.
- [x] The value lives only in the dialog's controller, is cleared on submit and on cancel, and is disposed
      with the dialog. Replace opens with an empty value field, a read-only name, and no reveal.
- [x] C4 38 new keys in `app_en.arb` and `app_ar.arb`, covering the whole task list; every
      `SecretsErrorCode` maps to localized copy and no Agent `message` text is rendered.
- [x] Stable driver keys on every interactive element (`secrets_add_btn`, `secret_row_<name>`,
      `secret_replace_btn_<name>`, `secret_delete_btn_<name>`, `secret_name_input`, `secret_value_input`,
      `secret_value_toggle`, `secret_save_btn`, `secret_cancel_btn`, `secret_delete_confirm_btn`,
      `secrets_retry_btn`, …).
- [x] Documentation: `client/lib/features/settings/AGENTS.md` records the destination, state,
      dialog-value, key, and copy laws.
- [x] Tests: 22 page and dialog widget tests, 2 navigation entry-point tests, and the C4 key-presence test
      in `test/core/locale_cubit_test.dart`; an RTL pump covers the list and both dialogs.
- [x] Merge (merged as PR #324, commit `2fed4227`; accepted live candidate `8b0fb5d9`).

Verification at the candidate commit: `fvm flutter analyze` clean; focused 31 passed; `test/guards/` 3
passed; full Client fast suite 2209 passed / 3 skipped (3m27s); `lint_wiki.dart` clean; `graphify update`
run.

### 140-05 — live acceptance + close-out — complete

- [x] Live acceptance steps 1–9 executed on one dedicated Test Home at candidate `8b0fb5d9`, every step
      PASS: empty state, add with metadata read-back, a real turn using the stored value, replace with an
      empty value field and an advanced `updated_at`, delete with confirmation followed by
      `secret_not_found`, daemon-restart persistence, a passive WebSocket harness that observed
      `secrets.changed` with `change` and `name` only, and a composer-card secret listed with
      `source=agent_request`.
- [x] Step 10 cloud parity verified by code inspection (owner decision 2026-10-24): `SecretsClient` →
      `DeviceCommandClient` → `DeviceConnectionCoordinator`, with no connection-scope branch in
      `SecretsCubit` or the page.
- [x] Canary scan clean: 0 occurrences in the agent log, the client log, `request_dumps/`, `state.db`, the
      harness frames, and both rendered page dumps; the post-cleanup re-scan was also 0. The step 4 echo
      turn produced `[REDACTED:DATABASE_PASSWORD]` in stored tool output and in session history.
- [x] `docs/qa_maintenance/secrets_screen_acceptance.md` written: scenario table with pass evidence and
      keys, the code-inspection proof for step 10, the canary-scan table, and the obstacles worth keeping.
- [x] `docs/product/settings_hub.md` Privacy & Security → Secrets section matches what shipped: source
      pill, description placeholder, empty state, unavailable banner with disabled actions, typed failure
      plus Retry, authoritative description clearing, and route-independent behavior.
- [x] Routing decision recorded in its owning documents: `docs/technical/communication_protocols.md` §3.2
      and `client/lib/features/devices/AGENTS.md`. The Client Tester connection-switching reference no
      longer presents a same-device local-gateway-off pair as the way to test the cloud route.
- [x] Close-out: task frontmatter closed at `remaining_estimate: 0%`, gates and DoD ticked with evidence,
      new acceptance doc indexed in `docs/llms.txt`, `fvm dart run scripts/lint_wiki.dart` SUCCESS.
- [ ] Merge (documentation-only PR).

## Out of scope

- Reveal, export, bulk import from dotenv text, rotation history, external secret managers, and a
  second "agent-readable environment" kind (a visible plaintext value) — none of these ship here.
- Usage metadata in the list — a last-used time or a "used by" hint: no such tracking exists today, and
  it would add agent-side bookkeeping and a new write path. Not in v1 (owner decision 2026-10-23).
- A dependency warning on delete — a stored secret name appearing in a saved schedule prompt or a
  recent command: no dependency tracking exists today. Not in v1 (owner decision 2026-10-23).
- Provider, MCP, and Sanad credential management: they keep their own screens and never appear in this
  list (K6).
- Any change to the vault backend, the `custom:` namespace, per-command injection, echo redaction, or
  the model's `system_request_secret` / `system_list_secrets` / `system_delete_secret` behavior.
