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
