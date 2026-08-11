# Local-First Onboarding Hierarchy

## Goal

Make desktop onboarding visibly local-first without presenting an unsupported local-agent action on mobile or web.

## UX Contract

- Desktop presents local installation as the primary large action and remote-device connection as a secondary underlined action.
- Mobile and web never present local installation. An authenticated user with no devices receives a focused empty state whose primary action adds a remote device.
- Unauthenticated non-desktop users remain routed to sign-in.
- Remote action labels continue to reflect authentication and registered-device state.

## Implementation

1. Extract the onboarding choice presentation into a platform-aware widget.
2. Preserve the existing local installation, authentication, existing-device, and add-device callbacks.
3. Update the product interface documentation.
4. Add widget coverage for desktop hierarchy and the non-desktop empty state.

## Definition of Done

- Desktop local setup is the only card-style primary choice.
- Desktop remote setup is rendered as an underlined secondary action.
- Non-desktop onboarding contains no local setup control and offers `Add a Remote Device` when authenticated without devices.
- Focused widget tests and `fvm flutter analyze` pass.

## Verification

- [x] `fvm flutter test test/widget/onboarding_setup_choices_test.dart`
- [x] `fvm flutter analyze`
