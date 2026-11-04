# iOS Post-Sign-In Device Inventory Recovery

## Goal
Make an iOS Client that returns from the Portal Universal-Link sign-in land on its device inventory within cold-start time, with no 10 second socket timeout, no false "No devices" surface, and no onboarding detour.

## Scope and locked decisions
- Live device evidence is the authority: a physical iPhone (iOS 27.0.1; hardware UDID kept out of this public record) reproduces the defect, and the fix is accepted only after a real Portal sign-in returns to the app.
- Root cause is fixed at the owning boundary instead of being hidden behind retries. Retries stay a bounded safety net; they are never the mechanism that makes inventory appear.
- Empty inventory is authoritative only after a real `get_devices` response. Transport readiness, socket identity, or a lifecycle transition never prove the inventory is empty.
- The connection controller owns reconnect semantics. `SanadSocketService` delegates; it must not bypass the controller guard with a direct `disconnect()`.
- Login during verification is owner-driven: Sign In is pressed in-app, the owner completes the browser sign-in, and the app returns automatically. No alternate login method is substituted on failure.
- Profile builds keep INFO lifecycle/socket/inventory diagnostics because on-device acceptance needs them; release builds stay silent.
- Release signs manually with the `Sanad App Store` profile; Debug and Profile stay automatic so local device runs and beta profiles keep installing.
- No secret, credential, token, or Portal URL parameter is logged in any diagnostic added here.

## Gates

### G0 — Discovery
- [x] Reproduce the defect on the physical device and capture the exact timelines: `resumed → Connecting ×2 → Connected → Disconnected id=null` after ~80 ms, a full 10 s `Connection timeout or error`, then a second connect with `auth_success` and a ~100 ms inventory response.
- [x] Establish that the 60 s gap observed earlier is the socket.io ping timeout and is a symptom, not the cause.
- [x] Trace the tearing call site instead of guessing: temporary `disconnect called id=... from=<stack>` diagnostics named `SanadSocketService.disconnect (sanad_socket_service.dart:175) <- SanadSocketService.reconnect (sanad_socket_service.dart:170)`.
- [x] Confirm the cold-start path (one connect, no resume reconnect) was always fast, so the defect is the resume-driven teardown and not connect latency or inventory size.

### G1 — Implementation
- [x] `socket_connection_controller.dart`: `reconnect()` skips a live, authenticating, or in-flight connection and returns the pending future instead of tearing it down; logs `reconnect skipped`.
- [x] `sanad_socket_service.dart`: `reconnect()` delegates to the controller so no caller can bypass the guard.
- [x] `app_auth_listener.dart`: post-sign-in refresh marks inventory pending, skips `connect()` when the socket is already connected, and retries once.
- [x] `device_cubit.dart`: pending/loading state derived from in-flight fetches and `hasAuthoritativeInventory`; a real error still wins over the pending surface; one no-change publish per fetch.
- [x] `device_repository.dart` / `device_repository_impl.dart` / `device_manager.dart`: expose `hasAuthoritativeInventory` as the only truthful empty-inventory signal.
- [x] `gateway_connection_cubit.dart`: a pending inventory keeps status `connecting` instead of routing to onboarding.
- [x] Composer surfaces: localized `devicesLoading` and `noDevicesChip` replace the `No Agents Found` literal; the slice carries `DevicesPhase`.
- [x] Driver keys for in-app verification: `nav_menu_btn`, `settings_menu_btn`, `sign_in_btn`.
- [x] Release signing contract: Release keeps manual signing with `Sanad App Store`; Debug/Profile return to `CODE_SIGN_STYLE = Automatic`.
- [x] Owning documentation updated: `client/AGENTS.md`, `docs/technical/client_authentication.md`, `docs/qa_maintenance/mobile_oauth_callback_qa.md`.

### G2 — Verification
- [x] `fvm flutter analyze` clean; `fvm flutter test test/unit test/tool` green with `1581` passing tests.
- [x] Regression coverage added: reconnect guard keeps a live connection, inventory pending vs. authoritative empty, gateway status during pending inventory, composer device-inventory states, navigation keys, Release-only manual signing.
- [x] Test doubles keep the naive reconnect so their overridden `connect`/`disconnect` still observe calls; production behaviour is asserted separately.
- [x] Live acceptance on the physical device after owner-driven Portal sign-in: `resumed 07:18:46.871 → Connected 07:18:47.309 → auth_success 07:18:47.392 → fetch.start 07:18:47.393 → count=9 07:18:47.482`, i.e. 611 ms resume→devices and 90 ms auth→devices.
- [x] Absence proof in the same run: no `disconnect called`, no `Disconnected id=null`, no `Connection timeout or error`, no false empty or onboarding surface.

### G3 — Delivery
- [x] Remove the temporary stack-based disconnect diagnostic, keeping only the bounded lifecycle log, then re-run analyzer and focused tests.
- [x] Commit inside `sanad-agent` with the `sanad-agent@eaststarai.com` identity and a plan-referenced message.
- [x] Open a labeled PR (`type/bug`, `comp/client`, `comp/ci-release`, `platform/ios`, `size/M`) and wait with `gh run watch --exit-status --compact` until the exact-head run settles.
- [ ] Squash-merge after approval, then re-pin the private `desktop-agent` gitlink to the new public main commit.
- [ ] Keep the `flutter_sficon` removal (ITMS-91182 `SFProText-Regular` in `sficons.ttf`, blocked from 2027-10-01) as a separate change, not part of this PR.

## Waivers
- Live device re-verification for this delivery is waived by the owner on 2026-11-04: acceptance rests on the recorded device run in G2 and was not repeated for the pull request. The two waived acceptance checks stay unchecked and are not reported as passed.

## Acceptance Criteria
- [ ] Given a signed-out iOS Client, when the owner completes Portal sign-in and the app returns, then exactly one socket connection is established and the inventory request is issued on it without any teardown.
- [ ] Given that return, then devices appear within about the cold-start time (observed 90 ms after `auth_success`) and never after a 10 second connect timeout.
- [x] Given a pending first inventory, then the device surface shows a localized loading state and never a false empty state, onboarding route, or error surface.
- [x] Given a real `get_devices` response with zero agents, then the empty state is shown only because the response was authoritative.
- [x] Automated coverage fails if `SanadSocketService.reconnect()` or the controller tears down a live or still-authenticating connection.
- [x] No user-visible English literal is introduced outside `AppLocalizations`.

## Definition of Done
Analyzer and focused unit/tool tests pass, owning contracts and technical/QA documentation describe the reconnect ownership law and the authoritative-inventory rule, live device evidence is recorded above, and delivery happens only after explicit owner approval. Remaining work at handoff: merge approval and the private gitlink re-pin.

## Current status
- Current gate: `G3 — Delivery` — implementation, diagnostic removal, commit, and pull request are landed on `fix/144-ios-post-signin-device-inventory`; squash merge and the private gitlink re-pin await owner approval.
- Live acceptance: waived for this delivery (see Waivers); acceptance rests on the recorded G2 device evidence.
- Remaining work: owner approval to merge, then re-pin the private `desktop-agent` gitlink to the merged public commit.
