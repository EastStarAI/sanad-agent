# Stable, Allowlisted Web Client Origin

## Goal

A Web Client that is stopped and restarted for the same Home, Client slot, and client
`ENVIRONMENT` returns to the same browser origin, so its one-time sign-in persists. A Web
Client whose origin the Portal in use cannot register is refused before any process
starts, instead of failing later at the sign-in button.

## Scope and locked decisions

- Root cause: `flutter run -d chrome` calls `findFreePort()` when no `--web-port` is given,
  so every restart minted a new origin and orphaned the browser-stored session; PR374's
  persistent Chrome profile cannot compensate because Web storage is keyed by profile
  **and** origin. The launcher only forwarded `SANAD_DEV_WEB_PORT` when a human exported it.
- The second half is not a bug: the Portal registers exactly one Web callback origin
  (`SANAD_PORTAL_WEB_CLIENT_ORIGIN`) and mirrors it in its credentialed CORS allowlist, so
  a loopback origin authenticates only against a loopback (local) deployment. Hosted
  `dev`/`staging`/`prod` accept only their served HTTPS Web app origin.
- The origin is derived from `(Home, client slot, ENVIRONMENT)` with the existing stable
  hash inside the reserved range `52000-52999`, which stays clear of the Agent
  (`58085-58185`) and VM-service (`51000-51999`) ranges.
- `SANAD_DEV_WEB_PORT` remains the single explicit override, so deployments that already
  pin an origin keep working unchanged.
- There is no fallback port. An occupied derived port refuses the launch with the origin
  and the override instruction.
- `--web-hostname=localhost` is passed explicitly: flutter_tools defaults the host to
  `any`, binds every interface, and only *reports* `localhost`.
- The preflight's authority is the resolved Portal endpoint, not the environment label,
  so an explicit loopback `PORTAL_URL` is verified and an explicit hosted one is refused.
- A refusal for a hosted environment is decided statically (no network). A loopback Portal
  is verified with the browser's own unauthenticated `OPTIONS /auth/client/transactions`
  preflight; an unreachable Portal warns instead of blocking.
- `--no-cloud` keeps pinning the origin but only warns, because that launch does not sign
  in. No new CLI flag is added.
- `status` reports the origin from the live Client's own argument vector (evidence, not a
  recorded claim), so the lease schema and ownership validation are untouched.
- Out of scope: hosted allowlist/OAuth changes (owner decision, reported separately), the
  `client/` Web auth code, ownership rules, and the `sanad-dev reset` surface.

## Gates

### G0 — Evidence
- [x] Trace the Web callback registration to the single exact Portal origin and its
      credentialed CORS allowlist.
- [x] Record the accepted origin per environment from the tracked deployment contract.
- [x] Confirm flutter_tools' `resolvePort(null)` free-port fallback, its `any` host
      default, and its fail-closed bind error on a taken port.
- [x] Confirm the reported symptom was a random origin, not a Client or Portal defect.

### G1 — Origin derivation and pinning
- [x] `lib/src/infrastructure/web_origin.dart` owns derivation, resolution, override
      validation, availability, preflight, and the Portal probe.
- [x] Chrome and `web-server` Clients receive `--web-port` and `--web-hostname=localhost`
      for direct and additional launches; native Clients receive neither.
- [x] An occupied port fails before spawn with a clear message and no fallback.

### G2 — Preflight
- [x] Hosted Portal + cloud enabled refuses before spawn, naming the origin, the reason,
      and the alternatives.
- [x] Loopback Portal rejection refuses with the exact registration variables; an
      unreachable Portal only warns; a disabled cloud gateway only warns.

### G3 — Observability
- [x] The run prints `Web origin: <origin>` once at launch.
- [x] `sanad-dev status` prints `web_origin=` per Web Client from its launch profile.

### G4 — Verification
- [x] `scripts/sanad_dev/test/infrastructure/sanad_dev_web_origin_test.dart` covers
      derivation stability/range/identity separation, override validation, collision
      refusal, preflight decisions, the live Portal probe, configuration recovery, launch
      preparation against the tracked production profile and a loopback Portal, and the
      command-line wiring of both launch paths.
- [x] `fvm dart analyze` in `scripts/sanad_dev` is clean.
- [x] The full `scripts/sanad_dev` suite passes, including the file-size ratchet after
      `runtime_summary.dart` was extracted from `runtime_run.dart`.

### G5 — Documentation
- [x] `scripts/sanad_dev/AGENTS.md` owns the deterministic-origin law.
- [x] `docs/technical/sanad_dev_runtime_ownership.md` owns the mechanism and preflight.
- [x] `docs/qa_maintenance/sanad_dev_runtime_ownership_qa.md` owns the verification rows.
- [x] `docs/technical/client_authentication.md` states why the origin is pinned and where
      a loopback origin can authenticate.
- [x] The client-tester runbook section records one-time sign-in per Home + slot +
      environment and the hosted limitation.
