# Task 152 — New-account onboarding on the mobile layout

## Goal

A brand-new account signed in on a phone can reach Settings and Sign out, sees
the post-create install page after creating a device, and can always open the
model/provider picker — including before any provider is configured — while the
same rules hold on desktop.

## Locked Decisions and Scope

- **Owner-approved design.** The four behaviours in the owner's App Store
  blocker report are the specification; no other design change is in scope.
- **D1 (a).** One shared shell chrome: `HomeShellScaffold` owns the side drawer,
  the drawer menu affordance, and the desktop-only status bar for the home
  surface and the mobile zero-device surface. `ConversationSidebarScope` owns
  the conversation cubits that drawer reads. Desktop onboarding keeps its
  local-first card and gains no drawer. No new sign-out control: the drawer's
  existing Settings/Profile path owns signing out, and the `section=` deep link
  resolves with zero devices.
- **Defect 2.** Onboarding routes to Home only while it is the live top route.
  `push` does not change the router's reported location, so the hosting route's
  own currency decides. The documented auto-continue when the created device is
  actually online is kept (D2 (a)).
- **Defect 3 / D3 (b).** The composer's model/provider picker is visible
  whenever no request is pending; `supports_model_change` is never a visibility
  gate. `conversation_bottom_actions.dart` keeps the same one-line rule even
  though the live composer no longer uses that widget. An always-mounted control
  must also fit: the chip label is flexible, single line, and ellipsized, and
  the standalone composer harnesses supply the conversation scope the picker
  reads.
- **Defect 4 / D4 (a).** No new gate logic. The existing shared gate (online
  device + authoritative `has_provider == false`) is covered end to end, and the
  gate container is clamped to the viewport.
- **D5 (a).** The two phone-width overflows on the screens this task rewrites
  are fixed (onboarding brand header, add-device header). The model picker
  dialog header's 5.8 px overflow is a follow-up.
- **Excluded:** the picker dialog header overflow, any new sign-out surface,
  any change to the provider-readiness gate conditions, deletion of the unused
  `ConversationBottomActions` widget, and the `_checkProviderReadiness` desktop
  redirect (same class of route theft, tracked as a follow-up).

## Gates

### G0 — Root cause
- [x] Root cause recorded per defect with file:line and runtime evidence
      (`mobile-onboarding/STUDY.md`).
- [x] Owner approval of D1–D5 recorded.

### G1 — Failing-first coverage
- [x] `client/test/widget/mobile_new_account_onboarding_test.dart` written
      against the pre-fix code and observed red for every defect.
- [x] Phone (390x844) cases use `AppPlatform` mobile overrides; desktop cases
      use 1400x1000.

### G2 — Implementation
- [x] `ConversationSidebarScope` extracted; `HomeScreen` and the mobile
      zero-device surface both use it.
- [x] `HomeShellScaffold` extracted; home (wide and compact) and the mobile
      zero-device surface render it.
- [x] `OnboardingSetupScreen` hosts the drawer on non-desktop and routes only
      from the live top route.
- [x] `SettingsScreen` resolves personal `section=` values without a device.
- [x] Composer picker visibility decoupled from `supports_model_change`.
- [x] Provider gate clamped to the viewport, with stable gate keys.
- [x] Onboarding card and add-device header fit a phone width.

### G3 — Verification and documentation
- [x] `fvm flutter analyze` clean.
- [x] Focused suites green: the new suite, the navigation suite, the composer
      chip/parity/inventory/toggle/paste suites, the sidebar suites,
      settings/schedules widget suites, guards, and the home/schedules route
      unit tests. CI's first run caught the narrow-composer overflow this change
      introduced; it is fixed and pinned by the 280 px case.
- [x] Owning contracts updated (`home`, `devices`, `provider_setup`,
      `conversations/presentation`), product doc updated, QA page added,
      `docs/llms.txt` indexed.

## Acceptance Criteria

- [x] Given an authenticated mobile account with zero devices, when the
      zero-device surface renders, then the side menu button is present, the
      drawer opens, and Profile shows the existing Sign out action.
- [x] Given zero devices, when `/settings?section=profile` is opened, then the
      Profile page renders (desktop and phone) instead of General.
- [x] Given the add-device flow opened from onboarding, when the created device
      enters the inventory offline, then the install page and its token stay on
      screen and the conversation surface does not replace them.
- [x] Given the created device becomes online, then the client continues to that
      device's New Conversation (documented completion).
- [x] Given a device with no capability snapshot, when Home renders, then the
      model picker is visible, opens, shows the empty-provider state, and keeps
      its Settings action.
- [x] Given an online device with no provider, when Home renders, then the
      provider setup gate opens; dismissing it leaves a usable conversation with
      a sendable composer.
- [x] Given an offline device or a failed readiness read, then no gate opens.
- [x] Given a phone viewport, the zero-device card and the add-device header do
      not overflow.

## Definition of Done

- [x] Analyzer clean; focused tests green (CI is the full-suite authority).
- [x] Documentation updated in the same change.
- [x] Graph maintenance: `graphify update .` after the change.
- [x] Live verification: the iOS Simulator scenario in
      `docs/qa_maintenance/mobile_new_account_onboarding_qa.md` remains for the
      owner's device run; this task's automated coverage stands in for it.

## Follow-ups

1. The model picker dialog header overflows by 5.8 px at 390 width
   (`model_picker_dialog.dart` header row) — deferred by D5.
2. `OnboardingSetupScreen._checkProviderReadiness` still routes Home without the
   top-route guard; the desktop local-gateway path can steal a pushed
   `/devices/add` page the same way.
3. `ConversationBottomActions` has no product call site but four test usages;
   delete it and retarget those tests in a separate cleanup.
