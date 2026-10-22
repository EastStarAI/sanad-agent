# Web Startup Platform Guard

## Goal
Restore Web startup after v1.0.18 by keeping native Client CLI initialization out of remote-only platforms and enforcing the existing AppPlatform boundary.

## Scope and locked decisions
- User authorizes a focused fix, verification, commit/push and a pull request; no merge, production deployment, release, private gitlink update or daily runtime mutation.
- AppPlatform remains the canonical platform discriminator. Shared composition must not directly inspect native Platform APIs. Genuine native filesystem/process implementations remain behind desktop-only boundaries; this task is not a repository-wide filesystem rewrite.
- Production v1.0.18 source ecbb442577d7a35a284f654ba3601be323590e41 fails before runApp: configureDependencies eagerly invokes ClientCliHomeResolver, whose dart:io Platform.environment throws in Web.
- Existing app_web_startup_contract_test checks app.dart only; require behavioral browser regression coverage, not only source string checks.
- Preserve native Client CLI and tray behavior and mobile/Web remote-only behavior. No new dependency unless strictly necessary and reviewed.

## Gates
### G0 — Discovery
- [x] Reproduce production failure in a clean browser and match the compiled stack to ClientCliHomeResolver.
- [x] Review AppPlatform, bootstrap, dependency composition, source tests and current deployment verification.
- [x] Inspect all consumers of ClientCliCubit/Host and shared startup native accesses before selecting the minimal coherent fix.
### G1 — Implementation
- [x] Isolate native-only dependency registration and consumption using AppPlatform.
- [x] Remove direct native platform inspection from touched shared composition; document the durable platform ownership law at its owner if missing.
- [x] Add focused native and remote-only regressions plus a real browser startup test that fails on the original bug.
- [x] Update owning technical/QA documentation.
### G2 — Verification and review
- [x] Client analyzer and focused tests pass; record exact commands, durations and exit statuses.
- [x] Browser runtime verification reaches the expected signed-out application UI without unhandled startup exceptions or indefinite splash; tests do not contact Production APIs.
- [x] Coordinator reviews full diff and independently reruns focused tests.
- [x] Graphify incremental maintenance completed; exclude unrelated generated graph churn from the PR.
### G3 — Pull request handoff
- [ ] Commit with sanad-agent@eaststarai.com identity, push and open labeled PR using the lifecycle skill.
- [ ] Observe exact-head CI, report required protected-review blockers without applying protected labels autonomously.
- [ ] Leave PR open and unmerged; preserve branch, no production or runtime mutations.

## Acceptance criteria
- [x] Web dependency setup never reads native environment or starts Client CLI, tray or desktop lifecycle.
- [x] Desktop native services retain their intended registration, lifecycle and settings behavior.
- [x] Web/mobile consumers do not require absent desktop dependencies.
- [x] Automated runtime coverage would detect v1.0.18's failure before an equivalent release is accepted.

## Definition of Done
All implementation/verification gates have evidence, owning docs are updated, and an open labeled PR is handed back without merge. Deferred deployment-workflow changes, if any, are explicit rather than claimed complete.

## Implementation record

### Discovery
- `configureDependencies()` resolved `ClientCliHomeResolver().resolveSanadHome(...)` at registration time in `client/lib/core/di/injection.dart`; `ClientCliHomeResolver` reads `dart:io` `Platform.environment`, which throws `Unsupported operation: Platform._environment` in Web before `runApp`.
- Consumers capable of pulling the Client CLI into remote-only startup were `AppProviders` (mounted `ClientCliCubit` and called `load()` on every platform) and `AppAuthListener` (`reconcile()` on login, `onLogout()` on logout). Settings already rendered `ClientCliSettingsCard` inside its `AppPlatform.isDesktop` block, and `AppBootstrap` already gated tray/lifecycle on desktop.
- `ClientCliApprovalCoordinator` and the approval overlay carry no native dependency; only the host, ownership record, settings cubit and Home resolution are native.

### Changes
- New `client/lib/features/client_cli/domain/client_cli_platform.dart`: `ClientCliPlatform.isSupported` is the single Client CLI platform boundary and defers to `AppPlatform.isDesktop`.
- New `client/lib/core/di/modules/client_cli_module.dart`: owns the native-only registration (`ClientCliOwnership`, `ClientCliHost`, `ClientCliCubit`), resolves the Sanad Home inside the host's lazy factory, keeps the shared `IDeviceRepository`, and fails closed (`StateError`) if invoked off desktop.
- `client/lib/core/di/injection.dart`: Client CLI registration is a single `if (ClientCliPlatform.isSupported)` call; shared composition no longer imports the Home resolver or resolves native state.
- `client/lib/core/presentation/app/app_providers.dart`: mounts the Client CLI settings cubit only inside the boundary.
- `client/lib/core/presentation/app/app_auth_listener.dart`: login reconcile and logout stop run only inside the boundary.
- `client/lib/core/bootstrap/app_bootstrap.dart`, `client/lib/app.dart`, `client/lib/main.dart`: remaining platform decisions go through `AppPlatform` (desktop-only startup tracing, Web URL strategy and resume branch instead of `kIsWeb`).
- Tests: new real-browser suite `client/test/web/web_startup_platform_guard_test.dart`, new native/remote-only suite `client/test/unit/client_cli/client_cli_platform_boundary_test.dart`, extended `client/test/tool/app_web_startup_contract_test.dart`, and `client/test/unit/client_cli/client_cli_inventory_contract_test.dart` retargeted at the new module.
- CI/release: `.github/workflows/ci.yml` (public `client` job) and `.github/workflows/release.yml` (`client-linux-web` job) run the Chrome guard with bounded output; the release-security workflow check asserts the command exists in both files.
- Owning docs: `client/AGENTS.md` (Platform Boundaries law), `client/lib/features/AGENTS.md`, `docs/technical/remote_cli_relay_protocol.md` (Platform Boundary), `docs/qa_maintenance/client_cli_remote_relay_qa.md` (G2.1 + enforcement), `docs/qa_maintenance/release_verification.md` (browser guard as a CI/release gate).

### Preservation of existing behavior
- Desktop keeps the same host, cubit, approval coordinator, tray and lifecycle wiring; the only timing change is that Home resolution now happens when the host is first constructed instead of during dependency setup.
- The approval coordinator stays platform-neutral so the desktop overlay keeps one owner on every platform.
- Mobile stays remote-only: it no longer registers a Client CLI cubit it never rendered or used.
- No dependency, no `pubspec` change, no native filesystem rewrite.

## Verification evidence
Bounded commands, all run from `client/` unless noted. External run artifacts
(writer logs and screenshot) live under the `sanad-delegate` run
`web-startup-platform-guard`, writer scope: `logs/*.log` and
`logs/web-startup-postfix.png`.

| # | Command | Result | Duration |
|---|---|---|---|
| 1 | `fvm flutter pub get` | exit 0 | 2.3 s |
| 2 | `fvm flutter analyze` | exit 0, no issues | 7.7 s |
| 3 | `fvm flutter test test/unit/client_cli test/widget/client_cli test/unit/infrastructure/platform/tray_manager_service_test.dart test/tool` | exit 0, 111 passed | 10.1 s |
| 4 | `fvm flutter test` (full fast suite) | exit 0, 2046 passed, 3 skipped (browser-only) | 2 m 41 s |
| 5 | `fvm flutter test --platform chrome test/web/web_startup_platform_guard_test.dart` | exit 0, 3 passed in real Chrome | 21.2 s |
| 6 | Same browser suite against the v1.0.18 wiring (temporary local revert of `injection.dart`, restored immediately) | exit 1, `Unsupported operation: Platform._environment` at `client_cli_home_resolver.dart:20 resolveSanadHome` | 22.3 s |
| 7 | `fvm flutter build web --release --dart-define-from-file=config/prod.json` | exit 0, `Built build/web` | 38.1 s |
| 8 | Release Web served on `127.0.0.1:8137` in a clean agent-browser session | Flutter view at ~1.2 s, signed-out shell rendered (`Sanad` + `Sign In`), no console or page errors, no indefinite splash | 34 s |
| 9 | `graphify update .` (repo root) | exit 0, 37299 nodes, 25.1 s; `graphify-out/` is git-ignored so no generated churn enters the PR | 25.1 s |

Runtime screenshot: `logs/web-startup-postfix.png` in the same external run
scope.
No Production API authentication, signing, deployment, runtime restart or Home
mutation was performed; the local browser session only loaded the static build.

Round 2 re-verification (comments/docs/workflows/test assertion only; gates 4 and
7 intentionally not repeated):

| Command | Result | Duration |
|---|---|---|
| `fvm flutter analyze` | exit 0, no issues | 7.8 s |
| `fvm flutter test test/tool/app_web_startup_contract_test.dart test/unit/client_cli test/web` | exit 0, 64 passed, 3 skipped | 6.8 s |
| `fvm flutter test --platform chrome test/web/web_startup_platform_guard_test.dart` | exit 0, 3 passed | 20.5 s |
| `ruby -ryaml` parse of `ci.yml` + `release.yml` | both parse | <1 s |
| `ruby scripts/community/validate_governance.rb` | exit 0, 43 labels / 18 YAML files | <1 s |
| `grep -F '<chrome guard command>'` in `ci.yml` and `release.yml` | both present | <1 s |
| `graphify update .` | exit 0, 37308 nodes | 27.2 s |

## CI enforcement
- `.github/workflows/ci.yml` — the `client` job runs the Chrome guard as its own
  step directly after `Test client`.
- `.github/workflows/release.yml` — the `client-linux-web` job runs the same
  guard before `fvm flutter build web`, inside the step's existing
  `set -euo pipefail` shell.
- Both use `set -o pipefail` with `2>&1 | tail -5` so the bounded output keeps the
  real exit status, and the release-security workflow check asserts the command
  is present in both files (`grep -F` on the exact command line).
- `.github/` is a protected path in this repository, so the PR delivery for this
  branch needs the `maintainer-reviewed` label from a maintainer; no label was
  applied here.

## Review repairs (round 2)
1. **CI/release enforcement** added to both jobs plus the workflow static check;
   previously the guard was only a documented command.
2. **Portable evidence paths**: the absolute user-home log path was removed from
   this task in favor of the external `sanad-delegate` run identifier.
3. **Contract trimming**: `client/AGENTS.md` now carries only the durable
   `AppPlatform` law and the desktop-only Client CLI invariant; locations and
   rationale stay in the technical doc and feature contract.
4. **Accurate disabled-feature wording**: registration performs no native read,
   but on desktop the host is constructed when a consumer mounts (settings
   cubit, tray, auth lifecycle), so Home resolution happens there regardless of
   the enabled setting. Module comments, feature contract and technical doc now
   state exactly that.
5. **Native boundary test**: keeps the desktop wiring assertion with an
   explained guarantee — resolving the host only computes the Home path, the
   host performs no I/O before `start()`/`stop()`, no lifecycle method is called,
   and `reset(dispose: false)` deliberately skips `host.stop()` so no ownership
   record is read or written in the operator Home. An absolute-path assertion
   replaced the previous implicit environment assumption; no test-only seam was
   added.
6. **Boundary abstraction**: `ClientCliPlatform` kept as a 15-line
   `AppPlatform.isDesktop` wrapper; no new product abstraction.

## Deferred and open items
- Follow-up observations, deliberately out of scope: `ActivityAnimationPolicy`
  and parts of `AuthService` still branch on `kIsWeb`/`dart:io Platform` inside
  their own feature boundaries, `AppConfig.isSourceRun` relies on a `try/catch`
  for Web, and `DesktopLifecycleManager`/`AppTrayService` remain lazily
  registered on all platforms while consumed only on desktop.
- `.github/` changes make the PR a protected-path change: the delivery step must
  request `maintainer-reviewed`; `release.yml` additionally sits on the
  `release-reviewed` path, so both protected labels apply to the same PR.
- G3 (commit, PR and CI observation only; no merge) remains assigned to a separate PR
  delivery delegation.

## Review handoff
- Review the platform boundary owner (`client/lib/features/client_cli/domain/client_cli_platform.dart`), the registration module, the three consumer guards, and the two workflow steps.
- Re-run `fvm flutter analyze`, the focused VM set (gate 3) and the Chrome guard (gate 5; requires Chrome). Round 2 changed only comments, docs, one test assertion and workflows, so the full suite (gate 4) and the release build (gate 7) were not repeated.
- Workflow checks that were rerun after the `ci.yml`/`release.yml` edit: `ruby -ryaml -e 'YAML.load_file(...)'` on both files, `ruby scripts/community/validate_governance.rb`, and the two `grep -F` assertions added to release-security.
- The key behavioral assertion is that `configureDependencies()` completes in Chrome and that Client CLI types are absent there, which gate 6 shows failing on the original wiring; gates 5 and the new CI/release steps are what make that assertion mandatory.

## Current status
G0–G2 accepted by coordinator after full diff review, clean analyzer, independent focused VM (111 tests) and Chrome (3 tests) reruns, YAML parse, governance validation and diff whitespace check. Release-Web signed-out screenshot and original-code red regression evidence reviewed. CI/release enforcement is wired. G3 delivery only is authorized; protected `maintainer-reviewed`/`release-reviewed` labels need maintainer authorization, and merge/deploy are forbidden.
