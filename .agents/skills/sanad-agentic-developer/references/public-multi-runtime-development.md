# Public Multi-Runtime Development

Use this reference when a contributor needs more than one managed Sanad Agent or Client at the same time. It covers one Agent with multiple Clients, multiple runtime groups from one workspace, and independent groups from multiple worktrees or clones.

Source runs use `client/config/prod.json` and enable Local plus public Production Cloud connections by default. Use `--no-cloud` only when the requested test is intentionally local-only.

## Runtime model

A managed runtime group contains:

- one launcher lease;
- one selected Sanad Home;
- zero or one Agent;
- zero or more launcher-owned Clients;
- one automatically isolated Agent port and one VM Service port per Client;
- one Client preference namespace per Home and optional Client slot.

The Sanad Home is the identity and mutable-state boundary. Do not share one Home between concurrently independent Agent groups or copy authentication state between Homes.

Run every command from the workspace that owns the source. `sanad-dev` uses that caller workspace plus the selected Home to discover and validate ownership.

## Preflight

From each owning workspace:

```bash
sanad-dev -h
fvm flutter devices
sanad-dev status
```

Before mutation, read the complete inventory. Continue only when the intended group is managed and `Cross-owned clients` plus `Unverifiable clients` are both zero. Do not select the newest process, guess a port, or act on another workspace's group.

Use `--background` for agent-issued or temporary-shell launches. Do not add another detachment wrapper around `sanad-dev`.

## Pattern A — One Agent with multiple Clients

Start the Agent and first driver Client:

```bash
sanad-dev run all --background --driver \
  -d macos \
  --client-instance macos-primary
```

Add Clients to the existing managed group. Use a stable, unique slot for every device/role combination:

```bash
sanad-dev run client --background --driver \
  -d chrome \
  --client-instance web-primary

sanad-dev run client --background --driver \
  -d <ios-device-id> \
  --client-instance ios-primary
```

A repeated device and slot is idempotent; a second Client on the same device needs a different slot:

```bash
sanad-dev run client --background --driver \
  -d chrome \
  --client-instance web-secondary
```

Inspect the group after every addition:

```bash
sanad-dev status
```

The status inventory is authoritative for each Client's device, slot-derived preference namespace, PID, and VM Service endpoint. UI automation can omit `--vm-url` only when exactly one managed driver Client exists. With multiple Clients, select the intended VM explicitly:

```bash
sanad-dev ui snapshot --compact \
  --vm-url <selected-client-vm-service-url>
```

Read bounded logs for one Client by its status-reported VM port:

```bash
sanad-dev logs client -n 100 --port <selected-client-vm-port>
```

Stop only one Client by its exact device and slot:

```bash
sanad-dev stop client \
  -d chrome \
  --client-instance web-secondary
```

Stop the complete owning group only when requested:

```bash
sanad-dev stop
```

## Pattern B — Multiple Agent groups from one workspace

Choose a distinct absolute Sanad Home for each group. Shell variables keep the commands readable; replace each quoted placeholder with a real absolute path before execution:

```bash
sanad_home_a='<absolute-sanad-home-a>'
sanad_home_b='<absolute-sanad-home-b>'
```

Start each group with its Home explicitly selected:

```bash
sanad-dev run all --background --driver \
  --home "$sanad_home_a" \
  -d macos \
  --client-instance group-a-macos

sanad-dev run all --background --driver \
  --home "$sanad_home_b" \
  -d chrome \
  --client-instance group-b-web
```

For every later operation, repeat the same explicit `--home` selector. Setting `SANAD_HOME` alone does not select a runtime for `sanad-dev` discovery or ownership:

```bash
sanad-dev status --home "$sanad_home_a"
sanad-dev logs agent -n 100 --home "$sanad_home_a"
sanad-dev ui snapshot --compact \
  --vm-url <group-a-client-vm-service-url> \
  --home "$sanad_home_a"
sanad-dev restart agent --timeout 60 --home "$sanad_home_a"
sanad-dev stop --home "$sanad_home_a"
```

Use the equivalent commands with `"$sanad_home_b"` for group B. Never omit `--home` midway through a non-primary group's lifecycle, even when the shell environment contains the same path.

Each Home receives independent identity, provider settings, databases, memories, runtime records, and Client preferences. Configure and authenticate each group through its own normal product flow.

## Pattern C — Multiple worktrees or workspaces

A linked worktree automatically receives its own worktree-derived Home and deterministic port candidates. From each worktree root, launch and inspect independently:

```bash
sanad-dev run --background --driver
sanad-dev status
```

Repeat those commands from the other worktree. Do not run one worktree's status, logs, UI, restart, reload, or stop command from another worktree.

A standalone clone can also own an independent group. If it uses a non-primary Home, pass the chosen absolute `--home` value to every command exactly as in Pattern B.

Never hardcode the usual Agent or VM ports for parallel groups. Read each group's live assignments from its own `sanad-dev status` output.

## Targeted operations checklist

Before any restart, reload, stop, or UI action:

1. Enter the owning workspace.
2. Pass the explicit absolute `--home` for every non-primary group.
3. Run `sanad-dev status` with that same Home.
4. Confirm the intended Agent and complete Client inventory.
5. Confirm zero cross-owned and unverifiable Clients.
6. For a Client action, select the exact device/slot or status-reported VM port.
7. Perform one mutation.
8. Re-run status and verify sibling groups did not change.

Useful targeted forms:

```bash
sanad-dev reload client \
  --port <selected-client-vm-port> \
  --home "$sanad_home_a"

sanad-dev restart client \
  --port <selected-client-vm-port> \
  --home "$sanad_home_a"

sanad-dev stop client \
  -d <device-id> \
  --client-instance <slot> \
  --home "$sanad_home_a"
```

Use `sanad-dev restart agent --timeout 60` for a safe Agent restart. Do not replace a refused restart or ownership check with direct process termination.

## Ownership failures

- **Cross-owned Client:** a Client points at this Agent but belongs to a different source or launcher identity. Do not mutate it; return to the owning workspace.
- **Unverifiable Client:** the process lacks enough exact launch identity to prove ownership. Do not attach, restart, or stop it through the managed group.
- **Multiple managed driver Clients:** pass `--vm-url` for the intended Client to `sanad-dev ui`.
- **Ambiguous Agent or launcher lease:** stop and diagnose bounded status/journal evidence. A port override is a selector, not permission to bypass ownership.
- **Stale status after a failed launch:** rerun `sanad-dev status`; a transitional or failed launch record never grants mutation authority.

## Cleanup

Stop each runtime from its owning workspace and with its owning Home selector. Remove a worktree only after its branch is merged or abandoned and its runtime is stopped. Keep the primary runtime and sibling groups running unless the user explicitly asks to stop them.
