# Linux Service Lifecycle QA

## Automated coverage

Run from `agent/`:

```bash
fvm dart test test/core/setup/service_manager_test.dart \
  test/core/setup/linux_service_manager_test.dart \
  test/core/setup/service_health_verifier_test.dart \
  test/core/setup/installer_transaction_test.dart \
  test/guards/cli_help_contract_test.dart
```

The focused suite must prove:

- generated systemd safety fields and argument quoting;
- user-systemd selection only after bus, linger, and manager probes;
- automatic system-scope fallback under the non-root invoking account;
- direct-root dedicated account and state-home behavior;
- native OpenRC install/start/stop/restart/status/uninstall;
- legacy user-unit migration without concurrent definitions;
- transactional restoration after activation failure;
- refusal to uninstall an unowned definition;
- typed `ManagerUnavailable` status instead of an empty state;
- unchanged Windows Scheduled Task command encoding and restart settings;
- bounded authenticated health retries for expected version and cloud registration;
- manifest 404, auth failure, service/health failure, binary restoration, pending
  pairing cancellation, and successful transaction commit;
- pairing authority absent from Agent process arguments and fake command logs;
- daemon/service help and unknown daemon arguments exit without daemon startup.

## Linux integration gates

Fake-process tests establish deterministic command, generation, and rollback
behavior. Before Task 81 can claim Linux environment support, run the following
on real clean hosts under G6 and G7:

1. Desktop user systemd with a live user bus and durable linger.
2. Headless systemd where no usable user bus exists.
3. Direct-root installation proving the daemon uid is not zero and the state
   tree belongs to the dedicated account.
4. OpenRC installation on a clean supported distribution.
5. SSH logout and reboot, followed by bounded polling for `Running` and Online.
6. Stop/start/restart/uninstall/reinstall and injected activation failure.
7. Verify exactly one definition exists for the selected Sanad Home and that
   uninstall preserves unrelated or unowned definitions.
8. Inspect status for state, enabled/running flags, scope, manager, and selected
   credential backend without exposing credentials.

OpenRC support must not be advertised as release-verified until its clean-host
integration gate succeeds.
