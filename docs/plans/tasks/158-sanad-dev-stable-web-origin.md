# Stable, Portal-Accepted Web Client Origin

## Goal

A Web Client that is stopped and restarted for the same Home and Client slot returns to the
same browser origin, so its one-time sign-in persists, and every Web Client is served from an
origin its owning deployment can register instead of an origin the browser would block.

## Scope and locked decisions

- Root cause: `flutter run -d chrome` calls `findFreePort()` when no `--web-port` is given, so
  every restart minted a new origin and orphaned the browser-stored session; PR374's persistent
  Chrome profile cannot compensate because Web storage is keyed by profile **and** origin. The
  launcher only forwarded `SANAD_DEV_WEB_PORT` when a human exported it.
- Second defect, measured live: a Web Client added or restarted by the owning launcher re-derived
  the origin from the *requesting* terminal's environment. `SANAD_DEV_WEB_PORT` is a
  launcher-startup variable, so the same slot could be served from two origins.
- One derivation applies in every environment: the port comes from `(Home, client slot,
  ENVIRONMENT)` with the existing stable hash inside `52000-52999`, which stays clear of the
  Agent (`58085-58185`) and VM-service (`51000-51999`) ranges. The Portal host never changes it,
  because a hosted deployment's credentialed CORS allowlist contains only its own hosted origins
  and cannot serve a `localhost` page at all.
- The port a slot served last is recorded at `<Home>/dev/web-origin.json` (secure runtime-file
  boundary) and preferred on a restart, so a signed-in session stays attached to its origin. A
  busy origin fails the launch with the origin, the environment, and the override; it is never
  silently replaced, because a different port is a different browser origin.
- `SANAD_DEV_WEB_PORT` remains the single explicit override, so deployments that already pin an
  origin keep working unchanged.
- A Web Client is legitimate in every environment, so a hosted Portal launch is allowed and
  prints exactly one warning: the page cannot sign in to or call that Portal because its CORS
  allowlist excludes `localhost`, and Web work with sign-in runs against the local Docker stack
  (`sanad-dev run client -d chrome --config config/local.json`), whose Portal registers the
  Home's origin.
- Owner decision (final): Production keeps its exact `redirect_uri` allowlist, so a localhost
  page can never receive the hosted callback, and no config-level redirect override is offered
  because any local page could then start a real hosted login. A private follow-up removes the
  remaining loopback origins from the hosted CORS lists; the launcher therefore never assumes a
  hosted Portal accepts `localhost`. A deployment-owned (loopback)
  Portal is still probed with the browser's own unauthenticated
  `OPTIONS /auth/client/transactions` preflight; a rejection prints the exact registration
  variables while the launch continues, and an unreachable Portal says nothing.
- `--web-hostname=localhost` is passed explicitly: flutter_tools defaults the host to `any`,
  binds every interface, and only *reports* `localhost`.
- `status` reports the origin from the live Client's own argument vector (evidence, not a
  recorded claim), so the lease schema and ownership validation are untouched.
- Out of scope: hosted allowlist/OAuth changes (owner decision, reported separately), the
  `client/` Web auth code, ownership rules, and the `sanad-dev reset` surface.

## Gates

### G0 — Evidence
- [x] Trace the Web callback registration to the single exact Portal origin and its credentialed
      CORS allowlist.
- [x] Capture the live Production Portal allowlist and `redirect_uri` behaviour
      (`POST /auth/client/transactions`) instead of reading it from source only.
- [x] Confirm flutter_tools' `resolvePort(null)` free-port fallback, its `any` host default, and
      its fail-closed bind error on a taken port.
- [x] Confirm the reported symptom was an origin problem, not a Client or Portal defect.

### G1 — Origin selection and pinning
- [x] `lib/src/infrastructure/web_origin.dart` owns the authority, candidate domain, selection,
      per-slot record, override validation, availability, guidance, and the Portal probe.
- [x] Chrome and `web-server` Clients receive `--web-port` and `--web-hostname=localhost` for
      direct and additional launches; native Clients receive neither.
- [x] A busy origin fails before spawn with a clear message and no fallback to another port.
- [x] The owning launcher carries the resolved port in `RuntimeComponentControlRequest.web_port`,
      so an additional or restarted Web Client keeps one origin regardless of the requester's
      environment.

### G2 — Launch reporting
- [x] A hosted Portal launches on the same derived origin and prints exactly one warning that
      the page cannot sign in to or call it, naming the local Docker stack command.
- [x] A loopback Portal rejection prints the exact registration variables and the Web callback;
      an unreachable Portal prints nothing.
- [x] No hosted launch is refused.

### G3 — Observability
- [x] The run prints `Web origin: <origin>` once at launch.
- [x] `sanad-dev status` prints `web_origin=` per Web Client from its launch profile.

### G4 — Verification
- [x] `scripts/sanad_dev/test/infrastructure/sanad_dev_web_origin_selection_test.dart` covers
      derivation stability/range/identity separation, authority, candidate domains, override
      validation, record persistence and recovery, next-free selection, and exhausted domains.
- [x] `scripts/sanad_dev/test/infrastructure/sanad_dev_web_origin_launch_test.dart` covers the
      command-line pinning, hosted guidance, local registration guidance, unreachable Portal,
      the live Portal probe, configuration recovery, and the wiring of both launch paths.
- [x] `fvm dart analyze` in `scripts/sanad_dev` is clean.
- [x] The full `scripts/sanad_dev` suite passes, including the file-size ratchet after
      `runtime_summary.dart` was extracted from `runtime_run.dart`.

### G5 — Documentation
- [x] `scripts/sanad_dev/AGENTS.md` owns the origin-domain law and the no-refusal rule.
- [x] `docs/technical/sanad_dev_runtime_ownership.md` owns the mechanism, the record, and the
      guidance.
- [x] `docs/qa_maintenance/sanad_dev_runtime_ownership_qa.md` owns the verification rows.
- [x] `docs/technical/client_authentication.md` states why the origin is stable and where a
      loopback origin can authenticate.
- [x] The client-tester runbook records one sign-in per Home + slot, the origin domain, and the
      hosted boundary.
