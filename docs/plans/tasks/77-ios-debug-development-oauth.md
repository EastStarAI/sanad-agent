# Task 77 — iOS Debug Development OAuth Callback

## Goal

Allow any Debug iOS build targeting Development—including Simulator and physical-device runs—to complete the normal Portal-owned Google/Apple sign-in flow without relying on iOS Universal Link association delivery.

## Security boundaries

- Keep S256 PKCE, transaction state validation, one-time authorization code redemption, and real Development credentials unchanged.
- Do not add a local authentication bypass, embedded credential, mock bearer token, or Production fallback.
- Select the custom-scheme callback only when all conditions hold: iOS, Debug mode, `ENVIRONMENT=dev`, and an explicit `SANAD_IOS_DEVELOPMENT_AUTH_REDIRECT_URI` value.
- Production, Staging, Profile, Release, TestFlight, and App Store builds continue to require their exact claimed HTTPS callback.
- Debug iOS Simulator and physical-device builds are both supported when compiled with the exact Development configuration.
- The Development callback uses a distinct Portal client registration so Production cannot accept it accidentally.

## Implementation

1. Add an explicit Development iOS callback value to the Development Client config.
2. Generalize exact mobile callback comparison while validating HTTPS for ordinary mobile clients and the `sanad` custom scheme only for the gated Development iOS client.
3. Select a distinct `sanad_flutter_ios_development` client id for that path.
4. Add focused unit and static contract tests proving exact matching and Production exclusion.
5. Update authentication design and QA documentation.

## Definition of Done

- `fvm flutter analyze` passes.
- Focused callback and platform-contract tests pass.
- Production config remains exact HTTPS and contains no Development callback.
- Development Portal separately registers the exact custom URI only when explicitly configured.
- A Debug iOS login completes through the real Development Portal on Simulator or a physical development device before acceptance.
