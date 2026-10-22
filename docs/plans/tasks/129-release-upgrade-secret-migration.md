---
title: "Task 129: Release Upgrade Gate — v1.0.17 to main (Plan 83 secret migration)"
description: "Live upgrade gate proving that an existing v1.0.17 Sanad Home migrates its legacy provider and MCP secrets into the Agent vault on the candidate build, with verified read-back, legacy deletion, restart idempotence, and a recorded downgrade consequence."
status: "complete"
current_gate: "Closed"
priority: "critical"
depends_on: "83c"
file_budget: 2
---

# Task 129: Release Upgrade Gate — v1.0.17 to main

## 1. Purpose

Plan 83 moved provider and MCP credentials out of plaintext Home files
(`provider_secrets.json`, `mcp_secrets.json`) into the Agent secret vault, and
`83c` deleted the legacy files after a verified migration. That makes the first
start of a new build on an existing v1.0.17 Home a release-critical path: a
migration defect would silently destroy a working provider or MCP credential.

This task verifies that path on macOS with the real v1.0.17 build and the
candidate build, agent only (no Client build), against an isolated Home.

## 2. Method

- Baseline: `v1.0.17` (`2114da35`, tag `v1.0.17`). Candidate: main `182d6a40`.
- Every daemon and CLI call ran with an isolated `HOME`, `SANAD_HOME` and a
  distinct `SANAD_STATE_HOME`, on verified-unused ports, with the cloud gateway
  disabled (`ENABLE_GATEWAY=false`). The real Home and every `~/.sanad-test*`
  Home were left untouched.
- Baseline legacy state was produced the way a real user produces it: the
  provider through the shipping `sanad setup` wizard (custom OpenAI-compatible
  endpoint with a dummy key, model list fetched from a local dummy endpoint),
  and the MCP server in the documented legacy shape because no version exposes
  an MCP-create CLI command. The legacy MCP state was then validated with
  v1.0.17 package code before the upgrade.
- Secrets were invented dummy values; only lengths and prefixes are recorded.
- Vault backend: the deterministic owner-file backend
  (`SANAD_E2E_TEST_MODE=true`), because this environment cannot authorize
  Keychain writes from an unsigned source process. See finding F3.

## 3. Result

| Step | Result |
| --- | --- |
| 1. v1.0.17 Home with legacy provider and MCP secrets, daemon clean stop | PASS |
| 2. Candidate migrates the same Home, secrets resolvable, doctor healthy | PASS |
| 3. Candidate restart: no re-migration, nothing lost | PASS |
| 4. Rollback: v1.0.17 on the migrated Home | PASS (downgrade note recorded) |
| 5. Cleanup | PASS |

Observed migration on the first candidate start:

```
[SecretVaults]: Migrated 1 providers: secret(s) into the Agent vault and deleted provider_secrets.json.
[SecretVaults]: Migrated 2 mcp: secret(s) into the Agent vault and deleted mcp_secrets.json.
```

Verified after migration:

- Both legacy files and their `.lock` sidecars are gone; `secret_vault_events.jsonl`
  is drained; `secret_vault.generation` and the vault store are present and
  owner-only (`0600`); `mcp_config.json` keeps only non-secret references.
- The vault holds `providers:index`, one `providers:<uuid>` record, `mcp:index`
  and both `mcp:mcp-secret://…` entries, and every value resolves through the
  product stores to the expected dummy credential (provider API key length 20,
  both MCP secrets length 20).
- A request built from the vault-resolved provider credential reached the dummy
  endpoint with `Authorization` length 27 (`Bearer ` + 20) and HTTP 200.
- `sanad setup status` reports the provider ready with model `dummy-model-v1`;
  `sanad doctor` reports every check green and a connected daemon.
- A second candidate start produced no migration event, recreated no legacy file
  and left the vault at the same five entries.

Downgrade note: v1.0.17 starts cleanly on the migrated Home and does not corrupt
the vault, but it cannot resolve any migrated secret — its credential store
reports `configured=false` and both MCP references resolve to absent. This is the
accepted no-downgrade decision recorded in `83c`.

## 4. Findings

- **F1 (Medium, pre-existing).** Readiness does not verify an optional-key
  provider's credential. With `provider_instances.status = 'ready'` and an empty
  vault, `runtimeCheck()` still returns `runtimeReady: true` with no reason,
  because `ProviderReadinessService._isApiKeyRequired` is false for the
  `Custom Provider` profile (`ApiKeyRequirement.optional`). Credential loss after
  migration (Keychain denied or reset, vault unavailable, or a downgrade) is
  therefore invisible to `setup status` and `providers`. The same code exists in
  v1.0.17, so this is not a regression introduced by the upgrade, but Plan 83
  makes the silent-loss case easier to reach.
- **F2 (Low, accepted).** Downgrade to v1.0.17 loses provider and MCP secrets,
  as designed.
- **F3 (Medium, verification gap).** The macOS Keychain backend could not be
  exercised live: an unsigned Dart process fails the vault write with
  `errAuthorizationInternal (-60008)`, and an AOT-compiled, ad-hoc-signed build
  fails with `errAuthorizationCanceled (-60006)` after about 25 seconds waiting
  for an authorization that cannot be granted autonomously. The migration logic
  was validated over the same `SecretVaults` code with the owner-file backend.
  Residual risk is judged low for a signed release build, which creates its own
  Keychain items, but this remains unverified.
- **F4 (Low, developer experience).** `--home` must precede the subcommand;
  `sanad daemon --home <path>` exits 64 with `Unknown daemon argument: --home` in
  both versions. v1.0.17 additionally applies Home selection after bootstrap
  (Task 126), so baseline isolation had to rely on `SANAD_HOME`.
- **F5 (Informational).** `doctor` reports `Agent Version: 1.0.17` on main
  `182d6a40`, because the version is only bumped by the release-prep commit; a
  version-string upgrade assertion would be misleading.

## 5. Follow-ups

- Track F1 separately: surface "credential missing" distinctly from "instance not
  ready" for optional-key providers, so a lost vault item or a downgrade cannot
  present as healthy.
- Run the same gate on a signed build of the candidate to close F3 for the macOS
  Keychain backend before a stable release claims Keychain migration coverage.

## 6. Progress log

```text
Date: 2026-10-22
Gate/status: complete (release gate closed)
Scope:
  - agent only, macOS arm64, candidate main 182d6a40 vs tag v1.0.17
Files changed:
  - docs/plans/tasks/129-release-upgrade-secret-migration.md
  - docs/llms.txt (index entry)
Verification:
  - v1.0.17 Home produced with the shipping setup wizard plus documented legacy MCP state; legacy files present (213/160 bytes, 0600) and resolved with v1.0.17 code.
  - Candidate migrated 1 provider and 2 MCP secrets, deleted both legacy files only after read-back, and kept mcp_config.json references intact.
  - Restart produced no migration event and no data change; doctor green.
  - Downgrade to v1.0.17 starts cleanly and cannot resolve migrated secrets (accepted).
  - Cleanup: gate daemons stopped, no Keychain item created, temp roots removed.
Findings:
  - F1 Medium (pre-existing): readiness reports ready without a resolvable credential for optional-key providers.
  - F3 Medium (verification gap): macOS Keychain path unverified from an unsigned source process.
Remaining work percentage: 0% for Task 129 verification; F1 and F3 are follow-ups.
Next gate: none for this task.
```
