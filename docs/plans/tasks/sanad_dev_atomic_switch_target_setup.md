---
title: "sanad-dev Atomic Switch Target Setup"
description: "Make one authorized source-switch command prepare its target checkout before submitting the runtime handoff."
status: "completed"
---

# sanad-dev Atomic Switch Target Setup

## Goal

Make `sanad-dev switch --runtime current` one operator action that prepares the
invoking target worktree before submitting its source-handoff transaction.

## Design

- POSIX and PowerShell wrappers run the existing idempotent install/setup stages
  for `switch` before entering the Dart runtime CLI.
- Target preparation accepts a functional user shim owned by another checkout;
  it must not steal global command ownership.
- Preparation failure exits before the switch manifest is submitted, leaving the
  current runtime unchanged.
- `already uses target` requires agreement between the Agent workspace hash and
  every managed Client source path; partial agreement fails closed as an
  inconsistent managed source.
- Other runtime commands retain their explicit prerequisite behavior.

## Verification

- Bootstrap tests prove an unprepared target is prepared before the Dart switch
  command executes.
- Bootstrap tests prove failed preparation never enters the Dart switch command.
- Client analysis plus focused bootstrap and runtime-source classification tests
  pass.
- Runtime ownership, developer, and QA documentation describe the unified
  operation.

## Verification evidence

- `bash -n scripts/sanad-dev` — passed.
- `fvm flutter test test/unit/scripts/sanad_dev_bootstrap_test.dart test/unit/scripts/sanad_dev_runtime_switch_test.dart` — 25 passed, 1 platform skip.
- `fvm flutter analyze` — passed with no issues.
- `git diff --check` — passed.
- `graphify update .` — completed; the existing large graph omitted HTML visualization.
- Authorized live handoff from `main` — completed after automatic target setup; post-switch status verified the retained managed Agent and macOS Client on the target source.

## Definition of Done

- [x] One `switch --runtime current` command prepares and submits the target.
- [x] Preparation failure leaves the source runtime untouched.
- [x] POSIX and PowerShell behavior remain aligned.
- [x] Focused tests and analyzer pass.
- [x] Graphify is updated.
