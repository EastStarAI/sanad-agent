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
| Callback filtering | Wrong scheme, host, port, path, user-info, or fragment is ignored; exact callback with non-empty code/state is delivered once. |
| Router ownership | `FlutterDeepLinkingEnabled=false`; callback query cannot become a GoRouter location or diagnostic. |
| Portal redirect | Mobile transaction registration is exact and OAuth completion redirects iOS from Portal to the configured Client host while retaining one-time PKCE code/state semantics. |
| AASA | Every Client host returns `200`, JSON, no redirect, exact app ID, and only `/oauth/ios`; Apple CDN matches. |
| HTTP fallback | Exact callback location has `access_log off`, strips the query with a no-store redirect, and does not proxy to app-site or Portal. |

## Physical iPhone gate

Use the owner-approved Development build and physical device. A restart or reinstall requires fresh owner approval.

1. Confirm the built app is signed by team `UC2824B99G` and its effective entitlements contain `applinks:dev.app.sanad.eaststarai.com`.
2. Verify origin and Apple CDN AASA responses without printing any authentication callback URL.
3. Start login from the app, complete provider authentication, and record only that Safari returned to Sanad and the app became authenticated.
4. Confirm callback redemption and authenticated socket startup using bounded, redacted logs. Search logs for key names/canaries only; do not print matching secret-bearing lines.
5. Treat Safari rendering either callback host, a `404`, a query-bearing fallback page, timeout, stale state, or Router navigation as a failed gate.
