# Connection switching verification

Load this reference only when validating transition between the local daemon gateway and cloud fallback without restarting the Flutter Client. Also load `runtime-and-worktrees.md` and `interactive-ui-testing.md`.

Cloud is enabled by default. Treat this as exclusive only when the scenario shares an external account, hardware identity, or other resource that cannot safely run in parallel.

## Setup

Launch a driver runtime with cloud connectivity. If the scenario needs to toggle the local gateway, apply process-level Agent overrides; do not edit tracked environment files.

- `ENABLE_LOCAL_GATEWAY=true` — local gateway takes priority.
- `ENABLE_LOCAL_GATEWAY=false` — cloud fallback remains active.

## Scenario

1. Start with the local gateway enabled.
2. Verify the passive `local` badge beside the active Agent through keyed UI inspection.
3. Send one message and verify routing through bounded daemon logs plus rendered response evidence.
4. Disable the local gateway and restart only the owned Agent; keep the Flutter Client running.
5. Wait for the `local` badge to disappear dynamically.
6. Send one message and verify cloud response rendering and the expected sanitized gateway lifecycle evidence.
7. Confirm the Client stayed responsive throughout the transition.

## Acceptance evidence

| Boundary | Required evidence |
| --- | --- |
| Routing | Sanitized daemon lifecycle shows the intended gateway |
| UI hydration | New keyed conversation body is rendered |
| Scope switch | Passive `local` badge changes without Client restart |
| Stability | UI remains responsive with no crash or freeze |

Logs alone are insufficient; pair them with exact UI evidence.
