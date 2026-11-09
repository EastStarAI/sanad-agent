---
title: "Vault Startup and Runtime Isolation"
description: "Task 151: no Agent start waits on or prompts for the OS credential vault (PR-1), and dev/test runtimes get their own vault namespace (PR-2)."
---

# Task 151 — Vault Startup and Runtime Isolation

## Goal

Two defects, one cause. A daemon used to open the operating-system credential
vault synchronously before it served anything, and it used to be allowed to start
an OS authorization dialog. On a Home whose items belong to another code identity
(the packaged Agent, an earlier release, or a different source runtime), that read
either blocks inside the security framework or is refused, so an operator sees the
same alarming block on every start and the daemon serves nothing until it returns.

The fix is split so each half is reviewable on its own:

- **PR-1 (this record, shipped):** no start waits on, or prompts for, the vault.
- **PR-2 (this record, awaiting review):** a dev/test runtime stops reading the
  app's items at all.

Source: the keychain study of 2026-11-09 (behaviour, file:line evidence, and the
option ranking). Owner decisions recorded below are binding.

## Owner decisions (2026-11-09)

1. Dev/test runtimes get a separate OS-vault namespace (PR-2). A plaintext file
   store stays an explicit opt-in only.
2. The packaged app and every daemon never start an OS authorization dialog at
   startup. A prompt only ever comes from an explicit user action.
3. No vault copy command. Development keys are re-entered once (PR-2 concern).
4. Exactly one WARNING line per start describing the current vault state; earlier
   recorded attempts are INFO only, deduplicated, and never replayed as current
   state.
5. The no-prompt rule applies on every OS (macOS Keychain, Linux Secret Service,
   Windows DPAPI): one contract.
6. `SANAD_SECRET_STORE` is a dev/test-only override (PR-2). It is not part of
   PR-1.

## PR-1 — no startup wait, no startup prompt (shipped)

### T1 — One honest state line, and a notice that only an interactive path prints

- `SecretVaults.logStartupState()` logs exactly one line per process describing the
  current state: a WARNING that names what is unreadable, the reason code, and the
  recovery route (`sanad vault authorize`) when the vault is closed; an INFO line
  when it is available or still opening. Repeated calls log nothing.
- `SecretVaults.drainStartupEvents()` replays recorded history at **INFO**,
  deduplicated (`repeated N times`), stamped `(recorded …)`, and never at the level
  that describes the current start. A closed vault is no longer recorded at all,
  because every start observes it itself.
- `SecretVaultNotice` owns the `Waiting for macOS Keychain approval …` line: once
  per process, only when the process may show the dialog, through an injectable
  sink. A refused query in a forbidding process prints nothing.
- The daemon no longer prints its own second warning; `bin/daemon.dart` dropped
  `_agentVaultUnavailableMessage` in favour of the vault's single state line.

### T2 — A daemon never prompts

- `SecretVaultInteractionEvidence.daemonEntryPoint` became `daemonBackground`
  (code `daemon_background`), and `SecretVaultPolicy.daemonEntryDecision` is now
  `forbidden`.
- The CLI no longer opens the vault on a daemon dispatch:
  `SanadCommandRunner.entryOpensSecretVault` is
  `!dispatchesToDaemon(arguments) && requiresSecretVault(arguments)`.
- `AuthManager` no longer owns a second store. DI injects the process's single
  `AgentSecretStore` (the vault's backend), so one process performs one Keychain,
  DPAPI, or Secret Service identity and one authorization decision.
- The policy test that asserted the opposite ("the daemon entry decision always
  allows the prompt") now pins `forbidden` / `daemon_background`.

### T3 — Explicit grant

- `sanad vault authorize` is the one path that may prompt: terminal-only,
  interactive, prints no value, and leaves the vault closed when it fails.
  `SanadCommandRunner.explicitGrantCommandFamilies` exempts the family from the
  entry open, so `sanad vault`, `sanad vault --help`, `--json`, and a piped
  invocation never start a dialog.
- Deferred to a follow-up (recorded, not implemented): the Client's
  "Grant access" action. It needs a short-lived, prompt-allowed helper process,
  because the daemon's process-wide interaction switch is not reversible and a
  daemon must never become the prompting process. That mechanism is its own
  security boundary and gets its own change; no Client UI or design work belongs
  in this task.

### T5 — The vault opens off the startup path

- `SecretVaults.beginOpen()` returns the instance immediately in
  `SecretVaultStatus.opening`, with `ready`, `isReady`, and a bounded
  `readyWithin(deadline)` that never throws. `open()` keeps awaiting `ready`, so
  every CLI path is unchanged.
- The daemon uses `beginOpen()`, so its banner, listener, durable restore, and
  `/health` come up while the store is still answering — or never answers.
- A secret read or write while opening fails with the new reason code
  `vault_not_ready` instead of reporting a value as absent.
- `AuthManager.initialize()` gates its Device Credential read on
  `readyWithin(secretVaultStartupReadyDeadline)` and degrades to "unknown
  credential", which keeps cloud registration's existing safe degradation.
- `ProviderCredentialResolver` reports `vault_not_ready` instead of
  "No API key configured", and `resolveAwaitingVault(deadline)` gives a caller
  that can wait one bounded opportunity to see the real answer.
- `/health` publishes `secret_vault: opening|available|unavailable`; `sanad doctor`
  reports `opening` as its own state.
- Linux Secret Service already refuses interactive authorization
  (`allowInteractiveAuthorization: false`) and refuses a locked collection, bounded
  by its D-Bus timeout; Windows DPAPI passes `CRYPTPROTECT_UI_FORBIDDEN`. With the
  daemon forbidden and the open deferred, neither can put an unlock on the startup
  path.

### Verification (PR-1)

- `agent/test/core/auth/secret_vault_test.dart`: deferred open (`opening`, bounded
  `readyWithin`, a write failing as `vault_not_ready`), one state line per start,
  deduplicated INFO history, and a closed vault that is never replayed as history.
- `agent/test/core/auth/secret_vault_interaction_policy_test.dart`: the daemon's
  `forbidden` decision, the notice sink (a refused query in a forbidding process
  prints nothing; an interactive grant prints once), and the existing status
  mapping.
- `agent/test/cli/cli_vault_open_policy_test.dart`: the classifier for a daemon
  dispatch and the `vault` family, plus `sanad vault authorize` through a refusing
  policy, an interactive grant, and a refused store.
- `agent/test/core/auth_test.dart`: a vault that has not answered keeps the daemon
  up without cloud authority and is never queried.
- `agent/test/core/provider_runtime/provider_credential_resolver_vault_readiness_test.dart`:
  `vault_not_ready` versus a real missing key, and the bounded await.
- `agent/tool/cli_aot_smoke.dart` (the `cli-automation` CI job) keeps asserting that
  a gateway command leaves no `secret_vault*` artifact and that `models list` opens
  the vault without printing the approval notice in a process with no terminal.

## PR-2 — runtime-kind vault isolation (implemented, awaiting review)

Design revised on 2026-11-10 after the migration study. The namespace is chosen by
explicit evidence only: a "compiled binary versus `dart`" signal and any other
inference were rejected, because a source run of the primary checkout holds the
same production items a packaged Agent does.

### T4 — `SecretStoreKind`

- `SecretStoreKind { app, dev, test }` carries the whole namespace: `service`,
  `secretServiceRuntime`, `vaultFileNamePrefix`, `credentialDataFileName`,
  `credentialLockFileName`. `app` keeps `ai.eaststar.sanad.agent` byte-identical;
  `dev` and `test` append `.dev` and `.test`.
- `resolveSecretStoreKind` reads `SANAD_RUNTIME_KIND` (set by `sanad-dev` for a
  linked worktree only), then the test runtime
  (`isSecretStoreTestRuntime()`), then `app`. An unrecognized declaration keeps
  `app` and emits one WARNING (`declared_unknown_runtime_kind`), because moving a
  Home on a typo would hide the items it already holds.
- The Home-derived account (`sha256(canonicalRoot):key`) is unchanged. On Linux
  the production filter carries no `runtime` attribute, so a pre-existing item
  still matches while a `dev`/`test` filter can never match it. On Windows the
  hashed file name is unchanged and only the prefix differs for non-app kinds.
- No migration and no copy command (owner decision 3): a development runtime
  re-enters its provider keys once, and `sanad vault authorize` remains the
  recovery route for an unreadable production item.

### T6 — Override and refusal contract

- `SANAD_SECRET_STORE=file|os` is a development/test override. `file` is refused
  for `app` (`file_store_refused_for_app`), `os` is refused inside a test runtime
  (`os_store_refused_for_test`), and an unrecognized value fails closed
  (`invalid_store_selection`).
- `/health` publishes `secret_store_kind` and `secret_store_service`; both name a
  namespace, never a value.
- `AuthManager` and `DeviceAuthorizationClient` alias their entry keys to
  `AgentSecretNamespaces`, so one definition serves the readers, the owner-file
  namespace, and the refusal diagnostic.

### Verification (PR-2)

- `agent/test/core/auth/secret_store_kind_test.dart`: kind identity (`app` stays
  byte-identical), resolution order, a malformed declaration, compiled-artifact
  detection, and override parsing.
- `agent/test/core/auth/agent_secret_store_namespace_test.dart`: both refusals, an
  invalid selection, dev/test file names, cross-namespace isolation on one Home,
  and a vault that reports its kind and service.
- `scripts/sanad_dev/test/runtime/lifecycle/sanad_dev_runtime_test.dart`: a linked
  worktree declares `dev`; the primary checkout declares nothing.
- `scripts/sanad_dev/test/infrastructure/sanad_dev_runtime_home_fixture_test.dart`:
  the dev/test credential files never enter a Home fixture.

## Follow-ups recorded here

- **`sanad doctor` namespace reporting:** `/health` now carries
  `secret_store_kind` and `secret_store_service`, but `doctor` does not print
  them yet. It should, so an operator can see which namespace a runtime addresses
  without reading `/health` directly.
- **`sanad-dev vault authorize` forwarder:** a worktree runtime must be able to
  reach the explicit grant for its own Home without hand-typing `--home`.
- **E2E namespace evidence:** a source daemon on a worktree Home must be proven
  to leave no `ai.eaststar.sanad.agent` artifact and no production credential
  file, using the `/health` fields above.

- **Client "Grant access"** (from T3): needs a prompt-allowed helper process and
  its own threat model. Until then the Client shows the vault state and points at
  `sanad vault authorize`.
- **Keychain Access is no longer the primary recovery route.** The state line and
  `sanad vault authorize` must stay the documented path; the Keychain Access steps
  remain only as a fallback for an item whose ACL names a foreign identity.

## Boundaries

- No secret value ever enters a log, a notice, a state line, `/health`, or a
  command's output.
- No path deletes a secret because the vault was closed.
- Tests and E2E subprocesses never reach a real OS credential vault: they use the
  owner-only file store inside an isolated Home.
