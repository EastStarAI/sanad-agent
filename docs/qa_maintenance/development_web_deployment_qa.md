# Development Flutter Web Deployment QA

## Static and build checks

| Check | Acceptance |
|---|---|
| Workflow trigger | Only public branch `dev` or an explicit manual dispatch can enter the Development Web workflow |
| Build profile | Flutter Web uses `client/config/dev.json` |
| Analysis | Flutter analyzer completes without errors before build |
| Build output | `build/web/index.html` exists and references `flutter_bootstrap.js` |
| Deployment Environment | GitHub Environment is `web-development` |
| Release identity | Server release directory is addressed by the exact public repository commit SHA |
| Production isolation | Workflow contains no Production Web path or selector |

## Pre-public server checks

| Check | Acceptance |
|---|---|
| Artifact transfer | Candidate build is complete inside an incoming directory before promotion |
| Atomic selector | Development Web selector changes only after `index.html` exists |
| Hosted mount | Private `app-site` mounts the Development Web selector read-only |
| CSP | Development API, WebSocket, and Portal origins are allowed; Production origins are not substituted |
| Host-header route | Candidate returns the Flutter bootstrap shell through the Development app virtual host |

## Public checks

| Check | Acceptance |
|---|---|
| HTTPS | `https://dev.app.sanad.eaststarai.com/` returns `200` with valid hostname verification |
| Flutter shell | Response contains `flutter_bootstrap.js` and the asset is retrievable |
| Security | HSTS, nosniff, and Development CSP are present |
| Gateway routing | Browser connects only to `dev.api.sanad.eaststarai.com` |
| Portal routing | Authentication starts only through `dev.portal.sanad.eaststarai.com` |
| Render | A clean browser creates the Flutter host element without CSP, CanvasKit, WebAssembly, font, or bootstrap errors |
| Rollback | Selecting the preceding Development Web release restores the last healthy shell |

A successful HTTP response without a rendered Flutter host element is not a
passing Development Web deployment.
