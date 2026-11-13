# 174f — Notification preferences and cross-platform verification

**Status:** not started — G0 open
**Owners:** `client/lib/features/settings/`, new `client/lib/features/notifications/`, `agent/` copy table
**Plan:** [174](../174-client-notifications-and-push-delivery.md)
**Depends on:** `174b`, `174c`, `174d`

## Goal

Give the user one coherent place to control notifications across every device,
and prove the whole feature on each platform with recorded evidence rather than
per-platform assumptions.

## Locked decisions and scope

1. Preferences are global plus per kind. There is no silent kind by default, and
   a kind can only be lowered by the user.
2. Preferences are per device, not per account, because a phone and a desktop
   have different tolerances; the Agent applies the preference of the device it
   is dispatching to.
3. All notification copy and settings text is localized in `en` and `ar`.
4. Verification is per platform and recorded here; a platform without recorded
   evidence is not complete.
5. No digest, quiet hours, or batching in this task.

## Gates

### G0 — Preference model

- [ ] Define the preference model: global enable, per-kind urgency, per-device
      scope, and the storage owner on each platform.
- [ ] Define how a preference change reaches the Agent for the device it applies
      to, without the relay interpreting it.
- [ ] Define the behavior when permission is revoked at the OS level while the
      in-app toggle is still enabled.

### G1 — Settings surface

- [ ] Add a notifications section that shows the OS permission state, the global
      toggle, and one row per kind with its current urgency.
- [ ] Provide a test notification action that exercises the real pipeline.
- [ ] Explain platform limits in place: iOS installed-web-app requirement, and
      the fact that OS settings always win.

### G2 — Localization parity

- [ ] Ensure the Agent copy table and the Client localization keys share one
      key set, enforced by a test.
- [ ] Ensure no user-facing string is hard-coded in widget code.
- [ ] Verify Arabic layout and right-to-left rendering of the notification
      settings.

### G3 — Cross-platform verification matrix

- [ ] macOS: permission, hidden-window delivery, click, action, quit limitation.
- [ ] Windows: permission, toast display, collapse behavior, cancellation
      limitation under NSIS.
- [ ] Linux: permission, display, click, action.
- [ ] Android: foreground same session, foreground other session, background,
      terminated, action, revoked token.
- [ ] iOS: foreground suppression for the same session, background, terminated,
      action, installed web app path.
- [ ] Web: closed tab, open tab same session, open tab other session, installed
      iOS web app.

### G4 — Failure and edge behavior

- [ ] Agent offline at dispatch time: the ask waits, and the Client shows it on
      reconnect without a stale OS notification.
- [ ] Relay unreachable: the dispatch fails closed with a recorded metric, and
      the in-app state remains correct.
- [ ] Duplicate delivery across socket and push: one visible notification.
- [ ] Escalation for an ask resolved on the first device: nothing arrives later.

### G5 — Documentation

- [ ] Record the final behavior, the platform limits, and the verification
      evidence in the owning technical documentation.
- [ ] Document the local-only limitation for cross-device notifications.

## Acceptance Criteria

- [ ] Given a user lowers one kind on one device, when that kind occurs, then only
      that device is affected and the other devices keep the default.
- [ ] Given the OS permission is revoked while the in-app toggle is on, when the
      settings page opens, then it reports the real state and offers a fix path.
- [ ] Given any supported platform, when the verification matrix row is executed,
      then its evidence is recorded in this file with date and build identity.
- [ ] Given the Arabic locale, when the settings page and a notification are
      rendered, then all text is translated and correctly aligned.
- [ ] Given an ask resolved on the first device, when the escalation window
      passes, then no other device is notified.

## Definition of Done

- [ ] `fvm flutter analyze` and `fvm dart analyze` pass.
- [ ] Focused tests pass; the platform matrix is complete with evidence.
- [ ] `docs/llms.txt` and the owning technical documents are updated.
- [ ] No hard-coded user-facing string and no Arabic literal in Dart source.
- [ ] Graph index refreshed with `graphify update .`.
