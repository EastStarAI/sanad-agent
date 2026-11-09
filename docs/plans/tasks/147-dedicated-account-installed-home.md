# Dedicated Service Account Installed-Home Resolution (Issue 353)

## Goal
A Sanad CLI invocation that names no Home (`--home` absent, `SANAD_HOME` unset) resolves the Home of the Agent installed beside it, so on a Linux root install that runs the unit as the dedicated `sanad-agent` account `service status` reports the health of the installed unit instead of inventing a second, empty `$HOME/.sanad` Home.

## Scope and locked decisions
- Root cause is Home selection, not service state: `getSanadHome()` (`agent/lib/core/constants.dart:72`) returned `SANAD_HOME`, else `$HOME/.sanad`. `ServiceManager._linux()` passes that value into `LinuxServiceManager` (`agent/lib/core/setup/service_manager.dart:433`), whose `status()`, `restart()`, `start()`, `stop()`, and `uninstall()` read `service.json` from it (`agent/lib/core/setup/linux_service_manager.dart:260`, `:308`, `:326`, `:349`). For the dedicated account `$HOME` **is** the Home, so the metadata read missed and `status()` fell through to the unit-exists loop that reports `Service exists without Sanad ownership metadata` (`:388`) while `restart()` reported `The Sanad service is not installed.` (`:312`).
- The fix owns Home selection, not the service manager: one shared resolver in `agent/lib/core/constants.dart` (`resolveSanadHomePath`) advances the order to `--home` → `SANAD_HOME` → **installed Home** → `$HOME/.sanad`, and the installed Home comes from `agent/lib/core/sanad_home/installed_home_record.dart`, the single owner of the install-record probe.
- The install record is the documented, non-secret ownership metadata `<home>/service.json` (`agent/lib/core/setup/service_metadata.dart`) beside the artifact `scripts/install.sh` places at `<home>/bin/sanad` (`BIN_DIR`/`TARGET`). Nothing new is written; no install format changes.
- Discovery is read-only and metadata-only: it stats `service.json` with `followLinks: false` and never opens `.env`, a credential, the vault, or any file content, so a discovery call can neither leak nor create state. A Home is accepted only for the exact artifact layout `<home>/bin/sanad` (or `sanad.exe`); a source run (Dart VM), a copy outside a Home, and a Home without the record keep the existing default.
- No privileged-message change here. Issue direction 3 (raw sudo text for a privileged restart by the dedicated account) is a separate owner in `LinuxServiceManager._runPrivileged` (`:784`) and is recorded as follow-up rather than widened into this PR.
- Platform limit: the record is written by the Linux service manager only. On macOS and Windows the installer always places the artifact and the unit in the user's default `$HOME/.sanad`, so the record-less fallback already resolves the Home the service definition names; a non-default Home installed on those platforms still needs `SANAD_HOME` or `--home`, and that limit is documented.
- Out of scope: dictation/voice files (PR 337), session deletion, Test Homes, `~/.sanad`, runtime start/stop, `scripts/bootstrap.sh`, and any live systemd execution (the coordinator owns the Linux host check).

## Gates

### G0 — Discovery
- [x] Read Issue 353 with its report of the disposable Ubuntu 24.04 run (PR 344 head `8f137fa0`).
- [x] Trace the resolution path end to end: `getSanadHome()` → `ServiceManager._linux(sanadHome:)` → `LinuxServiceManager` metadata reads → the two misleading outcomes.
- [x] Confirm the artifact/record layout in `scripts/install.sh` (`SANAD_USER_HOME`, `BIN_DIR=$SANAD_USER_HOME/bin`, `TARGET=$BIN_DIR/sanad`, root install → `/var/lib/sanad-agent`) and in `SystemServiceAccount` (`dedicatedHome`).
- [x] Reproduce with a compiled binary on macOS: `HOME=<home>` and `SANAD_HOME` unset with the artifact at `<home>/bin/sanad` and `<home>/service.json` reported `expected.sanad_home = <home>/.sanad`, and `service status` then created a stray `<home>/.sanad` (with `.env` and the vault lock) instead of reading the install record.
- [x] Confirm the plan number: `145` and `146` exist, open PR 304 owns `142`, no open PR or remote branch claims `147`.

### G1 — Failing test first
- [x] Add `agent/test/core/sanad_home/installed_home_record_test.dart` covering the record probe and the ordered resolution, including the dedicated-account shape (`$HOME` equal to the Home).
- [x] Run it before the fix and keep the red evidence: the resolver symbols did not exist, so the suite failed to load.

### G2 — Owning-layer fix
- [x] Add `agent/lib/core/sanad_home/installed_home_record.dart` as the only owner of "the Home this executable was installed into".
- [x] Add `resolveSanadHomePath` to `agent/lib/core/constants.dart` as the only owner of Home source order, and make `getSanadHome()` a composition of it, so no caller re-implements the order.
- [x] Keep discovery metadata-only and symlink-refusing; create nothing while resolving.

### G3 — Documentation
- [x] State the Home-selection law in `agent/AGENTS.md` and the record probe in `agent/lib/core/sanad_home/AGENTS.md`.
- [x] Document the dedicated-account resolution and the macOS/Windows limit in `docs/technical/linux_service_lifecycle.md`.
- [x] Add the dedicated-account row to `docs/qa_maintenance/linux_service_lifecycle_qa.md` gate 3d.
- [x] Index this task in `docs/llms.txt`.

### G4 — Gates
- [x] `fvm dart analyze` in `agent/`: `No issues found!`.
- [x] Focused suite (`test/core/sanad_home/`, `test/core/config_test.dart`, `test/core/setup/service_definition_inspector_test.dart`, `test/core/setup/service_manager_test.dart`, `test/core/setup/linux_service_manager_test.dart`): 139 tests passed.
- [x] Full fast Agent suite through the CI shards plus the isolated suite: shard 1 `+1205`, shard 2 `+990`, shard 4 `+971`, and `--concurrency 1 test/core/config_test.dart` `+43` passed. Shard 3 first reported `test/capabilities/file_tool_responsiveness_test.dart` (idle p95 43.5 ms against a 25 ms budget) while four `dart test` processes competed on this machine; that suite passed alone (7 tests) and the shard passed alone (`+1014`), so the failure is contention, not this change.
- [x] `fvm dart run scripts/lint_wiki.dart` from the repository root: `SUCCESS: All documentation files are valid, indexed, and healthy!`.

### G5 — Delivery
- [ ] One commit in `.agent/worktrees/lt-issue353`, PR against `main` whose body carries `Fixes #353`, mandatory `type/*` and `comp/*` labels, `platform/linux`, and CI green.
- [ ] No merge; the maintainer decides.

## Acceptance criteria
- [x] Given `SANAD_HOME` unset and no `--home`, when this process's executable is `<home>/bin/sanad` and `<home>/service.json` exists, then the resolved Home is `<home>`.
- [x] Given the same layout and a recorded Home whose value is also the account's `$HOME`, when the CLI resolves a Home, then it never selects `$HOME/.sanad`.
- [x] Given `--home` or `SANAD_HOME`, when either names a Home, then it selects that Home and the install record is not consulted.
- [x] Given an executable that is not `<home>/bin/sanad` (a Dart VM source run, a copy outside a Home), when the CLI resolves a Home, then the OS user default is used exactly as before.
- [x] Given a Home without `service.json`, or with a symlinked `service.json`, when the CLI resolves a Home, then the record yields no Home and no stray directory is created.
- [x] Discovery reads no file content: the probe only stats the record.
- [x] Compiled-binary evidence: `service definition` reports the installed Home and `service status` creates no second Home.
- [ ] Live Linux: `runuser -u sanad-agent -- /var/lib/sanad-agent/bin/sanad service status` reports `Running` with `Scope: systemd-system`, and no `/var/lib/sanad-agent/.sanad` appears (coordinator-owned host check).

## Definition of Done
- [x] Analyzer, focused tests, full fast Agent suite, and documentation lint pass with bounded output.
- [x] Owning contracts, technical page, and QA matrix updated in the same change.
- [ ] Pull request opened with the mandatory labels and green CI; merge and Issue closure left to the maintainer.
- [x] Live Linux verification listed with exact commands for the coordinator.

## Current status
G4 is closed: analyzer, focused suites, the full fast Agent suite through the CI shards, and the documentation lint all pass. Remaining work is G5 delivery (commit, pull request, labels, CI) and the coordinator-owned live Linux check.

## Implementation record

### Pre-fix evidence (macOS, compiled `bin/sanad_agent.dart` placed at `<home>/bin/sanad`)
```
expected.sanad_home = <home>/.sanad
State: Missing / Installed: No
--- stray Home created ---  <home>/.sanad/{.env, secret_vault.lock}
```

### Post-fix evidence (same fixture)
```
expected.sanad_home = <home>
State: Missing (no launchd job in this fixture)  --- no stray Home created
copy outside <home>/bin  -> <home>/.sanad
SANAD_HOME=<chosen>      -> <chosen>
no service.json          -> <home>/.sanad
```

### Follow-up (not in this change)
- `LinuxServiceManager._runPrivileged` (`agent/lib/core/setup/linux_service_manager.dart:784`) surfaces the raw `sudo` failure text when the dedicated account asks for a privileged restart it cannot perform; a Sanad-owned message naming the administrator command is the remaining half of Issue direction 3.
- An administrator who runs the installed CLI as root now resolves the account's Home and therefore bootstraps and reconciles it as root. `sudo systemctl restart sanad-agent.service` needs no Home at all and stays the recommended privileged action; the install hint keeps naming the Home-scoped command that this change makes correct.
