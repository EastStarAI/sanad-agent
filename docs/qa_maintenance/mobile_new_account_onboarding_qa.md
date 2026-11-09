# Mobile New-Account Onboarding — QA

Verification for a brand-new account on the mobile layout: reachable account
controls, the post-create install page, the always-available model picker, and
the provider setup gate. The same scenarios are checked on a desktop-width
window because the shared shell, picker, and gate are one implementation.

## Automated matrix

`client/test/widget/mobile_new_account_onboarding_test.dart` — 17 tests.

| Defect | Case | Viewport | Asserts |
| --- | --- | --- | --- |
| 1 | zero-device surface offers the side menu | 390x844 | menu button present, drawer opens, Profile shows `sign_out_btn` |
| 1 | `section=profile` with zero devices | 390x844 | Profile page, not General |
| 1 | `section=profile` with zero devices | 1400x1000 | Profile page, not General |
| 1 | desktop onboarding keeps its local-first card | 1400x1000 | local install action, no drawer |
| 2 | post-create install page stays | 390x844 | token and install commands remain, no conversation surface |
| 2 | created device online continues to Home | 390x844 | New Conversation for that device |
| 2 | pushed install page never moves | 1400x1000 | install page keeps the screen while the device is offline |
| 2 | add-device header fits a phone | 390x844 | no overflow, name still readable |
| 3 | picker visible with no capability snapshot | 390x844 / 1400x1000 | picker opens, empty-provider state, Settings action present |
| 4 | online device without a provider opens the gate | 390x844 / 1400x1000 | gate opens with a close action |
| 4 | dismissed gate leaves a usable conversation | 390x844 | gate closed, composer still sendable |
| 4 | configured runtime never opens the gate | phone | no gate |
| 4 | offline device never opens the gate | phone | no gate |
| 4 | readiness failure never opens the gate | phone | no gate |

Regression suites that must stay green with this change: the conversation
navigation suite, the composer chip/parity/inventory suites, the sidebar
structure and pagination suites, the settings and schedules widget suites, the
repository guards, and the home/schedules route unit tests.

## Manual scenario — iOS Simulator

Run the Client on an iOS Simulator with the local Agent and a fresh account that
owns no devices.

1. Sign in and stop on the zero-device screen. Confirm the side-menu button is
   visible and that the card fits the screen with no overflow stripe.
2. Open the side menu, choose Settings, then Profile. Confirm the Profile page
   renders and offers Sign out (do not sign out).
3. Return to the zero-device screen and choose `Add a Remote Device`. Enter a
   name and create the device.
4. Confirm the install page appears with its commands and pairing token, and
   that it stays on screen while the device is still offline.
5. On the host, install the Agent with that token. When the device comes online,
   confirm the Client continues to the new conversation for it. Re-run the
   scenario and use `Continue to Home` instead to confirm the manual path.
6. With the device online and no provider configured, confirm the provider setup
   gate opens over the conversation. Dismiss it and confirm the composer is
   still usable; the model picker opens, states that no providers are
   configured, and its Settings action opens provider settings.
7. Configure a provider, return to the conversation, and confirm the picker
   lists that instance's models and the gate no longer opens.
8. Repeat steps 1–7 in a desktop-width window (and on macOS) and confirm the
   same outcomes, with the desktop onboarding card keeping its local-install
   primary action and no drawer.

## Expected evidence

- No overflow stripes on any step.
- No case where the install page is replaced while the device is offline.
- No case where a phone user cannot reach Settings, Profile, or Sign out.
- No case where the picker is missing for an unconfigured device.

## Follow-ups observed in this pass

- The model picker dialog header overflows by 5.8 px at 390 width.
- `OnboardingSetupScreen._checkProviderReadiness` can still route Home from
  under a pushed `/devices/add` page on the desktop local-gateway path.
