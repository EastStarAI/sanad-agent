# Managed runtimes and worktree isolation

Load this reference before manual/custom interactive UI work or when launching, discovering, restarting, or stopping a Client runtime. Do not load it before a supported canonical conversation-runner invocation; use it only if that runner reports a runtime ownership/discovery failure.

## Ownership model

Use `sanad-dev` from the current checkout/worktree. It resolves the caller Git worktree, allocates isolated daemon and VM-service ports, records runtime metadata, and gives linked worktrees one isolated `SANAD_HOME` for identity, providers, databases, memories, dumps, and Client preferences. The primary checkout retains the normal user Home.

Do not infer ownership from directory naming, newest process, or a hardcoded port. Do not edit tracked `.env`/JSON configuration, set `SANAD_STATE_HOME`, or hand-allocate ports unless diagnosing the launcher itself.

## Launch and discovery

```bash
sanad-dev run --driver
sanad-dev status
```

Local and cloud gateways are enabled by default. Use `--no-cloud` only for explicit local-only verification. For an agent-owned disposable run that must survive a non-TTY shell, use the official detached mode:

```bash
sanad-dev run --background --driver --no-cloud
```

Do not wrap `sanad-dev run` with `nohup`, `screen`, `script`, shell `&`, or equivalent process-detachment workarounds.

If launch used `--home <absolute>`, later commands from the same workspace normally infer that validated active Home. Pass `--home` later only as an authoritative override or to disambiguate multiple custom groups.

Before acting, `sanad-dev status` must prove that the current worktree owns the expected Agent, Client, Home, and endpoints. If status reports a managed Client but a Client command rejects it, use the status-reported VM endpoint with the standalone driver CLI as a diagnostic fallback; do not infer that the Client is stopped and do not repair or stop it automatically.

## Web Client sign-in and origin

A Web Client stores its signed-in session only in browser `localStorage`, which is
scoped to the Chrome profile **and** the page origin. `sanad-dev` therefore pins
both: the persistent profile at `<Home>/dev/chrome-web/<slot|primary>` and a
stable origin — `http://localhost:<port>` — chosen from the domain the Portal in
use actually accepts. One sign-in per Home + slot + environment is then enough —
a `stop` + `run client -d chrome` for the same Home and slot returns to the same
signed-in Client. Signing in again means the origin or the profile changed.

One derivation applies in every environment: a port inside `52000-52999` derived
from Home, slot, and client environment, which the local deployment registers. A
busy origin fails the launch with the origin and the override instead of moving to
another one, and the port a slot served last is recorded under `<Home>/dev/`, so a
restart resumes the existing browser session. `SANAD_DEV_WEB_PORT` overrides the
choice for both direct and additional Web Clients.

Verify the origin from `sanad-dev status` (`web_origin=http://localhost:<port>`),
never from the VM-service port or the requested CLI value, and remember that
`localhost` and `127.0.0.1` are different origins.

A loopback Web origin can authenticate only against a Portal that registers it.
That is the local deployment: its Portal must carry the exact origin in
`SANAD_PORTAL_WEB_CLIENT_ORIGIN` and `SANAD_PORTAL_CORS_ORIGINS`, and the Backend
must allow it in `BACKEND_CORS_ORIGINS`; the callback path is
`<origin>/oauth/callback`. The launcher probes the local Portal's CORS preflight
and prints those exact variables when the origin is rejected; it never blocks the
launch.

A hosted Portal launch is allowed but prints one warning: the page cannot sign in
to or call that Portal, because its CORS allowlist excludes localhost, and Web work
with sign-in runs against the local Docker stack
(`sanad-dev run client -d chrome --config config/local.json`), whose Portal
registers this Home's origin. That is the owner decision — hosted Web sign-in
belongs to the deployed Web app — so verify hosted Web behavior there and use the
local stack for local Web work that signs in.

## Runtime actions

Use bounded log reads; never use follow mode from an agent tool call:

```bash
sanad-dev logs client -n 50
sanad-dev logs agent -n 50
sanad-dev reload client
sanad-dev restart client
sanad-dev restart agent
sanad-dev stop
```

Stop only a disposable runtime launched for the current test and proven to be owned by the current worktree. Do not stop the active current-checkout runtime during live in-place self-development. Runtime source switching is outside normal test authority and requires explicit user authorization under the repository contract.

## Multi-worktree verification

When changing discovery or ownership logic, run two managed driver runtimes concurrently. From each owning worktree, verify `snapshot`, `find`, `enter-text`, and `screenshot`; restart or stop one Client and prove the other worktree remains independently controllable. Selection must use the caller worktree's validated lease and exact `client/lib/driver_main.dart` profile.

## Manual fallback

Direct Agent or Client commands are diagnostic fallback only while debugging the launcher or one process in isolation. Supply one explicit absolute `SANAD_HOME`, clear inherited `SANAD_STATE_HOME` using platform-appropriate syntax, inject ports inline, and keep the run local-only unless the scenario explicitly requires cloud behavior.
