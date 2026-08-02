---
title: "Task 71: sanad-dev Shared Release Contract Bootstrap"
description: "Make every sanad-dev invocation validate the shared release contract and dependent Agent/Client package graphs before entering the Dart runtime CLI."
status: "completed"
current_gate: "Complete — implementation, focused scripts suite, and analyzer passed"
priority: "high"
depends_on: "Task 64 sanad-dev bootstrap"
design_contract: "docs/technical/sanad_dev_runtime_ownership.md"
qa_contract: "docs/qa_maintenance/sanad_dev_runtime_ownership_qa.md"
---

# Task 71: sanad-dev Shared Release Contract Bootstrap

## Problem

Explicit commands such as `sanad-dev run --config config/dev.json` currently skip package bootstrap. After the shared release package moved or its package graph changed, stale Agent or Client package configurations can still point at the former source path and fail compilation. The shared package itself is also absent from the setup fingerprint and readiness check.

## Scope

- Use a layered command contract: mutation-free help, tool-only `install`, package-owning `setup`, and readiness-orchestrating `run`.
- Validate the pinned Flutter SDK and package setup before `run` enters `scripts/sanad_dev.dart`; non-run runtime commands fail with recovery guidance instead of bootstrapping.
- Stream real install/setup stdout/stderr with stage duration and outcome.
- Resolve `release/contract` before its Agent and Client consumers.
- Bind the setup stamp to all three lockfiles and package configuration files.
- Keep shim installation exclusive to explicit setup/no-argument bootstrap.
- Apply equivalent behavior to POSIX and PowerShell wrappers.
- Keep a proven managed runtime authoritative when additional unmanaged Client processes are present; commands target only the lease-owned inventory.
- Keep `run client` in the invoking terminal, reserve a Client sidecar for `run all`, and expose `r`/`R` controls in every managed Agent/Client terminal.

## Definition of Done

- No arguments show help without mutation; install/setup stop at their documented boundaries.
- A fresh or stale explicit `run` repairs tools plus Contract, Agent, and Client package graphs in dependency order.
- Work-performing setup stages expose live child output, duration, and result.
- English and Arabic README quick starts identify `sanad-dev run` as the official source command.
- An unchanged invocation skips all package resolution work.
- Failure in Contract resolution prevents Agent, Client, and runtime CLI execution.
- Hermetic bootstrap tests cover the new order and explicit-command path on supported platforms.
- Runtime design, developer guidance, QA matrix, and the closest launcher contract describe the durable behavior.
- Run/stop/reload/restart selection ignores extra unmanaged Clients when one exact managed target exists, while duplicate managed targets still fail closed.

## Verification

- POSIX wrapper syntax validation passed.
- Client analyzer passed with no issues.
- The complete `client/test/unit/scripts` suite passed: 100 tests, with one Windows-only test skipped on macOS.
- No runtime start, stop, restart, or source switch was executed during verification.
