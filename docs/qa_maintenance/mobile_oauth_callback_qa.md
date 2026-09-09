---
title: "SEC-01E Mobile OAuth Callback QA"
description: "Regression and physical-device gates for PKCE callback delivery through Android App Links and iOS Universal Links."
---

# SEC-01E Mobile OAuth Callback QA

## Security and delivery invariants

- Provider callbacks terminate on the environment Portal host. The iOS redirect is the matching Client host at exact path `/oauth/ios`, ensuring the final Safari navigation is cross-domain.
- Android continues to use the matching Portal host at exact path `/oauth/android`.
- iOS AASA binds only `UC2824B99G.com.eaststarai.sanad` and `/oauth/ios`; the signed app's effective Associated Domains claim the three Client hosts.
- `app_links` subscribes before browser launch and is the sole Flutter callback owner. `FlutterDeepLinkingEnabled` remains false, while AppDelegate preserves Flutter superclass lifecycle delegation for application and scene callbacks.
- Flutter accepts only the configured HTTPS scheme, host, port, and path, then requires non-empty code and state. AuthService compares state with its in-memory transaction before redeeming through the original S256 PKCE verifier.
- Logs and QA evidence may contain host, path, response status, lifecycle reason, and a boolean callback-delivered result. They must never contain query, fragment, authorization code, transaction state, verifier, access token, or refresh token.
- If iOS association fails and HTTP reaches `/oauth/ios`, edge access logging is disabled and the response redirects immediately to a query-free, no-store failure page. Flutter Web and Portal do not receive callback parameters.

## Automated matrix

| Scenario | Required result |
|---|---|
| Production config | iOS uses `https://app.sanad.eaststarai.com/oauth/ios`; Android remains on Portal. |
| Development/Staging injection | iOS uses the matching `dev.app`/`staging.app` host and never a Portal host. |
| Entitlements | Exactly the intended Client Associated Domains are present; old Portal claims are absent. |
| iOS lifecycle | AppDelegate registers plugins and calls `super.application(...didFinishLaunching...)`; no override swallows `continue userActivity` or scene delivery. |
| Callback filtering | Wrong scheme, host, port, path, user-info, or fragment is ignored; exact callback with non-empty code/state is delivered once. The Development custom scheme is accepted only by a Debug iOS build compiled for Development and never by Profile/Release or Production config. |
| Router ownership | `FlutterDeepLinkingEnabled=false`; callback query cannot become a GoRouter location or diagnostic. After redemption, `/login` redirects to bootstrap without preserving `/login` as `from`; stale auth-only or external bootstrap destinations fall back to `/home` instead of creating a redirect loop or 404. |
| Portal redirect | Mobile transaction registration is exact and OAuth completion redirects iOS from Portal to the configured Client host while retaining one-time PKCE code/state semantics. |
| AASA | Every Client host returns `200`, JSON, no redirect, exact app ID, and only `/oauth/ios`; Apple CDN matches. |
| HTTP fallback | Exact callback location has `access_log off`, strips the query with a no-store redirect, and does not proxy to app-site or Portal. |

## Environment promotion matrix

| Environment | Portal/provider host | Exact iOS callback and AASA host | Android callback host | Accepted iOS artifact |
|---|---|---|---|---|
| Development | `dev.portal.sanad.eaststarai.com` | Signed device/Profile: `https://dev.app.sanad.eaststarai.com/oauth/ios`; any Debug iOS run: exact `sanad://oauth/ios-development` through `sanad_flutter_ios_development` | Development Portal | Signed Profile build with explicit Development defines, or Debug Simulator/physical device with the explicit Development-only callback define. |
| Staging | `staging.portal.sanad.eaststarai.com` | `https://staging.app.sanad.eaststarai.com/oauth/ios` | Staging Portal | Signed Profile or release-candidate build with explicit Staging defines; never Production or Development configuration. |
| Production | `portal.sanad.eaststarai.com` | `https://app.sanad.eaststarai.com/oauth/ios` | Production Portal | Signed Release/archive build using `client/config/prod.json`. |

The public commit consumed by a hosted environment must be reachable from public `main`; do not pin a content-equivalent PR-head SHA after squash merge. Every environment uses bundle `com.eaststarai.sanad` and team `UC2824B99G`, but environment callback inputs and evidence remain isolated.

## Promotion gate

For each environment, complete these checks in order:

1. Confirm the source includes all three Client-host Associated Domains, `FlutterDeepLinkingEnabled=false`, Flutter superclass lifecycle delegation, and `app_links` as sole callback owner.
2. Confirm the hosted Portal registers the exact environment callback, derives iOS from that environment's Client origin, keeps provider/Android callbacks on Portal, and rejects the old same-host iOS URI.
3. Verify Client-host AASA origin independently from Apple's CDN inspection endpoint. Record CDN propagation separately; a CDN `404` is an open propagation result and must not be hidden by origin or device evidence.
4. Inspect the built artifact—not only source files—for team, bundle, effective target Associated Domain, and embedded exact target callback. A Debug build may run only through Flutter tooling/Xcode; Home-screen or device-tool acceptance uses Profile for Development/Staging and Release for Production.
5. Reinstall only with owner approval so iOS refreshes association registration. Complete real provider login on a physical iPhone and record only that Safari returned to Sanad, PKCE redemption completed, and authenticated socket startup succeeded.
6. Treat Safari rendering either callback host, a `404`, a query-bearing fallback page, app termination, timeout, stale state, or Router navigation as a failed gate. Logs/evidence must never include query, fragment, code, state, verifier, access token, or refresh token.
7. Run lower-environment regressions before accepting Staging or Production. A source merge, health response, stack deployment, AASA origin response, or edge reload alone is insufficient.

## Physical iPhone gate

Use the owner-approved environment build and physical device. A restart or reinstall requires fresh owner approval. Development passed with a signed Profile build on 2026-08-12; Staging and Production require their own artifact and evidence and cannot inherit Development acceptance.
