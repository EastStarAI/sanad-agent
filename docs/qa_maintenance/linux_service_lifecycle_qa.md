---
title: "Linux Service Lifecycle QA"
description: "Automated coverage and clean-host integration gates for the Linux Agent service lifecycle."
---

# Linux Service Lifecycle QA

## Automated coverage

Run from `agent/`:

```bash
fvm dart test test/core/setup/service_manager_test.dart \
  test/core/setup/linux_service_manager_test.dart \
  test/bin/service_test.dart \
  test/cli/sanad_command_runner_test.dart \
  test/core/setup/service_health_verifier_test.dart \
  test/core/setup/installer_transaction_test.dart \
  test/guards/cli_help_contract_test.dart
```

The focused Agent suite must prove:

- generated systemd safety fields and argument quoting;
- user-systemd selection only after bus, linger, and manager probes;
- explicit `--user-scope` installation succeeding under active user bus with `Linger=no` without invoking sudo or modifying linger;
- explicit `--user-scope` failing with typed `ManagerUnavailable` without system/OpenRC fallback when the bus or systemctl probe fails;
- explicit `--user-scope` failing when attempted as root;
- `SanadCommandRunner` service install parsing and argument forwarding for `--user-scope`;
- `agent/bin/service.dart` option parsing and guards accepting `--user-scope` while rejecting unknown options and invalid combinations without host mutation;
- automatic system-scope fallback under the non-root invoking account for default durable installs;
- direct-root dedicated account and state-home behavior;
- a root install entered through sudo producing the identical account and Home as a direct root install, and the installer never consulting `SUDO_USER`;
- the installer's default dedicated Home equal to the Agent's shared policy constant (drift guard across the shell and Dart implementations);
- `--run-as-user <account>` registering that existing account with its own Home and ownership, refusing an unknown account before any download, refusing a non-root install, and accepting `root` only by name with a warning;
- the unit's account owning the Home the installing process wrote — a recursive ownership transfer and `0700` on the Home and `logs/` that runs after the startup files exist and before activation, a first install succeeding on a clean Home without a second run, and no transfer when the unit runs as the account that created the Home (`--run-as-user root`, user scope);
- the installer stopping before download and pairing (exit `71`) when a surviving definition names another Home, with the exact removal command;
- a service-account access preflight that refuses an `ExecStart` or working directory the unit's account cannot reach, before the definition is written or activated, and that keeps installing when the probing tool is absent;
- a health window that polls the Home's Local Gateway credential until it appears and that fails with the credential message and the real attempt count when it never does;
- native OpenRC install/start/stop/restart/status/uninstall;
- legacy user-unit migration without concurrent definitions;
- transactional restoration after activation failure;
- refusal to uninstall an unowned definition;
- typed `ManagerUnavailable` status instead of an empty state;
- unchanged Windows Scheduled Task command encoding and restart settings;
- bounded authenticated health retries for expected version and cloud registration;
- manifest 404, auth failure, service/health failure, binary restoration, pending
  pairing cancellation, and successful transaction commit;
- a root Linux install without `SANAD_HOME` using the dedicated account Home, an
  existing populated root Home left in place, a non-root install keeping the
  invoking account Home, and the retry message a failed pairing attempt prints;
- pairing authority absent from Agent process arguments and fake command logs;
- daemon/service help and unknown daemon arguments exit without daemon startup.

Run from `client/`:

```bash
fvm flutter test test/unit/services/local_daemon_controller_test.dart
```

The focused Client suite must prove:

- Linux daemon registration passes `--user-scope` to `sanad service install`;
- macOS and Windows omit `--user-scope`;
- registration output sanitization removes ANSI sequences and control characters;
- output length is bounded to at most 120 characters;
- unsuitable output (stack traces, JSON objects, internal shell command invocations, tokens/credentials) is rejected;
- raw subprocess stdout and stderr are never logged; only non-sensitive exit code and diagnostic presence metadata are logged;
- sanitized concise diagnostic line is propagated to `AgentLifecycleResult.message`;
- clean fallback to generic failure message when output is empty or unsuitable.

## Linux integration gates

Fake-process tests establish deterministic command, generation, and rollback
behavior. Before Task 81 can claim Linux environment support, run the following
on real clean hosts under G6 and G7:

1. Desktop user systemd with a live user bus and durable linger.
2. Headless systemd where no usable user bus exists.
3. Direct-root installation proving the daemon uid is not zero, the state tree
   belongs to the dedicated account, and the account can execute the unit's
   `ExecStart` and enter its `WorkingDirectory` (the artifact and the daemon's
   Home are the same Home, `/var/lib/sanad-agent`);
3b. The same installation invoked through `sudo` (`sudo -i`, `sudo bash install.sh`,
   `curl … | sudo bash`, with `SUDO_USER` set to the invoking cloud-image
   account) producing the identical unit, the identical Home, and no failure
   after the device authorization;
3c. `install.sh --run-as-user <account>` on a clean host: the printed account and
   Home, a unit whose `User=` is that account, the account's ownership of the
   startup files `service install` wrote (`secret_vault.lock` included), a
   daemon that becomes healthy on that first run, and a refusal (before
   download) for an unknown account or a non-root invocation;
4. OpenRC installation on a clean supported distribution.
5. SSH logout and reboot, followed by bounded polling for `Running` and Online.
6. Stop/start/restart/uninstall/reinstall and injected activation failure.
7. Verify exactly one definition exists for the selected Sanad Home and that
   uninstall preserves unrelated or unowned definitions.
8. Inspect status for state, enabled/running flags, scope, manager, and selected
   credential backend without exposing credentials.
9. Packaged Linux desktop Client bootstrap with `Linger=no` creates, enables,
   and starts the user systemd service without elevation prompts (`sudo`/`pkexec`).
10. User-scoped service without linger stops on user session logout and resumes
    when the user logs in interactively.
11. Simulated registration failure in the Client propagates a concise, sanitized
    diagnostic to the UI rather than an unhelpful generic error or raw command dump.
12. `sanad service stop` on systemd ends `inactive (dead)` rather than `failed`,
    `sanad service status` reports `InstalledStopped`, and the Agent is not
    restarted; a unit installed before `SuccessExitStatus=130 143` shows the
    `failed` state until `sanad service install` refreshes it.
13. A clean direct-root install succeeds on its first attempt: the health window
    observes the daemon's Local Gateway credential appear after activation
    instead of requiring a second run against an already-started daemon.

OpenRC support must not be advertised as release-verified until its clean-host
integration gate succeeds.
