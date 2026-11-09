# Persistent, Home-Scoped Chrome Profile for Web Clients

## Goal
A Web Client started with `-d chrome` keeps its signed-in session across a controlled restart of that Client for the same
Home and instance slot, because `sanad-dev` stops letting flutter_tools create a throwaway temporary browser profile.

> Superseded in part by
> [158-sanad-dev-stable-web-origin.md](158-sanad-dev-stable-web-origin.md): the stable default Web port this record
> deferred is now required, because the profile alone cannot resume a session whose origin changes.

## Scope and locked decisions
- `flutter run -d chrome` creates `flutter_tools_chrome_device.*` in the system temp directory unless the caller passes
  `--user-data-dir` inside `--web-browser-flag`; the Web Client keeps its tokens and device identity only in `localStorage`,
  which browsers scope to the profile directory plus the origin. The temporary profile is therefore the whole defect.
- The port and the shared-preferences namespace are already deterministic per Home. Neither changes here: a stable default
  Web port was explicitly **out of scope for this record** (see the superseded note above), and `SANAD_DEV_WEB_PORT` was
  its "random unless set" policy until plan 158 replaced it with a stable, Portal-accepted origin chosen per Home and slot
  and reused across restarts.
- The profile directory is `<SANAD_HOME>/dev/chrome-web/<slot|primary>`: runtime state beside the launcher lease, created
  through the existing secure runtime-file boundary so the chain is `0700`, and already excluded from Home fixtures because
  the fixture allowlist never captures `dev/`. Nothing is copied from any existing user browser profile.
- Automatic for every Chrome Client, with no opt-in flag, because the isolation rule and the existing ownership, allocation
  and QA contracts already describe the capability.
- An inherited `--web-browser-flag=--user-data-dir=` is replaced, never duplicated, so the launcher can reapply the flag for
  an additional Chrome Client exactly as it reapplies the Web port.
- Native devices receive no browser flag and cause no `dev/` write.
- A Home path containing a comma fails closed before spawn: flutter_tools declares `--web-browser-flag` without
  `splitCommas: false`, so a comma would silently become two browser flags.
- `sanad-dev reset` does not own `dev/` cleanup today (it owns `dev/homes`), so its scope is not widened; the new directory
  is documented instead, and it is deleted with the Home.
- Out of scope: `client/`, `agent/`, ownership, lease, launch-profile validation, and the source-handoff switch vector, which
  builds its own client arguments and today carries neither the Web port nor this profile.

## Gates

### G0 — Reproduction and boundaries
- [x] Trace the Web Client's only persistence surface to `localStorage` through `shared_preferences`, with no secure
      storage, IndexedDB, or cookies in the Client.
- [x] Trace the Chrome launch to `Process.start('fvm', flutterArguments)` and the profile decision to flutter_tools
      `_createUserDataDirectory`, which honours a caller-supplied `--user-data-dir` and otherwise creates a temp directory.
- [x] Confirm the repository's own contracts already claim this behaviour (tool `AGENTS.md`, runtime-ownership technical doc,
      runtime-ownership QA table) so this closes a contract-to-code gap instead of adding a feature.
- [x] Confirm the owning production file is at 680 of the 700-line cohesion limit, so the new module must be its own file.

### G1 — Failing tests
- [x] Add `scripts/sanad_dev/test/infrastructure/sanad_dev_web_chrome_profile_test.dart` covering a Chrome Client's flag and
      directory, slot separation, native-device silence, inherited-flag replacement, comma rejection, a Windows Home shape, an
      unsafe slot and an empty Home, plus a guarded call site in the switch controller.
- [x] Observe the suite failing for the missing API before any production change.

### G2 — Implementation
- [x] Add `scripts/sanad_dev/lib/src/infrastructure/web_chrome_profile.dart` with the pure directory builder and the argument
      application, using `secureRuntimeDirectory` for creation and `0700`.
- [x] Extract the instance-slot grammar into `isValidSanadDevClientInstanceSlot` so the preference namespace and the profile
      directory share one validator; the existing invalid-slot test still throws, so behaviour is unchanged.
- [x] Wire the import and apply the profile next to `applySanadDevWebPort` in `runtime_run.dart` and in
      `switch_controller.dart` for additional Chrome Clients.

### G3 — Verification
- [x] `fvm dart test test/infrastructure/sanad_dev_web_chrome_profile_test.dart`: 8 passed.
- [x] `fvm dart test test/infrastructure/sanad_dev_client_launch_profile_test.dart test/cli/sanad_dev_size_guard_test.dart
      test/runtime/switch/sanad_dev_runtime_switch_test.dart`: 47 passed.
- [x] `fvm dart analyze` in `scripts/sanad_dev`: `No issues found!`.
- [x] `fvm dart run scripts/lint_wiki.dart` from the repository root.
- [x] Update the tool contract, the runtime-ownership technical doc, the runtime-ownership QA table, and the authentication
      doc's persistence paragraph.

## Acceptance criteria
- [x] A Chrome Client's Flutter vector carries exactly one `--web-browser-flag=--user-data-dir=<Home>/dev/chrome-web/<slot|primary>`.
- [x] The directory is created owner-only (`0700`) inside the Home and is not created for native devices.
- [x] Reapplying the profile replaces the previous flag, so an additional Chrome Client reuses the same profile.
- [x] A Home path containing a comma fails closed before any directory is written, with a message that names the cause.
- [x] The instance slot cannot escape the profile root (`../escape` and `Web_Primary` both fail).
- [x] Native Client launches, ownership checks, the launcher lease, and launch-profile validation are untouched.
- [x] No credential, token, or profile content is copied, read, or written by this change.

## Definition of Done
- [x] Analyzer clean, focused tests green, documentation lint clean.
- [x] Owning contract (`scripts/sanad_dev/AGENTS.md`) and the technical/QA documents updated in the same change.
- [x] The "never share" note is recorded: the profile holds a refresh token at rest, so it stays inside the Home, `0700`, and
      never leaves the machine in a fixture, an archive, or a bug report.
- [ ] Pull request opened against `main` with the mandatory `type/*` and `comp/*` labels and pushed for review; merge remains an
      owner decision.

## Implementation record

### Where the state lives
The Web Client stores the access/refresh pair (`backend_auth_session_v1`), the device identity (`hardware_id`), and the Client
instance identity (`client_instance_id_v1`) in `shared_preferences`, which on Web is `window.localStorage` under the
prefix derived from the Home and the instance slot. That store is scoped to the browser profile plus the origin, so the port
and the profile together decide whether a restart resumes the session.

### Launch path
`handleRun` builds the Flutter vector, applies the Web port, then applies the Chrome profile; the resulting vector becomes the
launcher's client arguments, which the switch controller copies for an additional Chrome Client and re-applies both settings
to. The profile flag travels as a browser argument, so launch-profile extraction, ownership validation, and the lease are
unaffected.

### Consequences to know
- The first run after this change has no profile yet, so it signs in once; later restarts of the same Home and slot resume.
- A leftover Chrome that still holds the directory makes the next launch fail with Chrome's profile-in-use error instead of
  silently starting a second profile; quitting that Chrome or removing the directory recovers.
- The source-handoff switch builds its own client vector and carries neither the stable port nor the profile, so a
  switch-spawned Chrome Client still starts a fresh browser session.
- The new test file is beside `sanad_dev_client_launch_profile_test.dart`, which is at 668 of the 700-line cohesion limit,
  so it could not be extended in place. CI's `sanad-dev-platforms` step runs a fixed test list, so this file is verified
  locally and by `fvm dart analyze`; adding it to that list is a `.github/` change that needs the `maintainer-reviewed`
  label and is left as its own follow-up rather than smuggled into this fix.
