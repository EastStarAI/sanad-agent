# Connection switching verification

Load this reference only when validating a transition between the local daemon gateway and the cloud route without restarting the Flutter Client. Also load `runtime-and-worktrees.md` and `interactive-ui-testing.md`.

Cloud is enabled by default. Treat this as exclusive only when the scenario shares an external account, hardware identity, or other resource that cannot safely run in parallel.

## What a cloud leg is

A real cloud live leg runs on **Test Homes configured for the cloud**: two Test Homes, one Agent and one Client per Home, both signed in, both devices present in the same account, and the command dispatched to the **remote** Home. The observing Client resolves the remote device through the cloud route while its own local daemon stays reachable.

Never produce a cloud leg by turning the local gateway off for a same-device Agent and Client:

- A same-device Agent and Client are always connected locally. The supported configurations are local only, and local + cloud where the cloud route is additionally available.
- A same-device pair that talks only through the cloud relay, with `ENABLE_LOCAL_GATEWAY=false`, is **not a supported configuration**. It is not a default and not a user option, and it is not a valid cloud test setup.
- Behavior observed in that shape is a consequence of the configuration, not a defect, and must not be reported as a bug or "fixed": for example Settings omitting the same-hardware device row (the local inventory row is removed when it is not locally reachable, which also removes the device-scoped settings group) or a turn that does not dispatch. Changing that behavior risks the two supported cases. See `docs/technical/communication_protocols.md` §3.2 and `client/lib/features/devices/AGENTS.md`.

Do not edit tracked environment files to force a route. Apply process-level Agent overrides only on the manual diagnostic path, and only to reach a configuration this reference declares supported.

## Same-device local route

1. Start a driver-enabled runtime with the local gateway enabled.
2. Verify the passive `local` badge beside the active Agent through keyed UI inspection.
3. Send one message and verify routing through bounded daemon logs plus rendered response evidence.

A same-device cloud fallback is only observable as a transient during a daemon restart or local socket loss. That transient is not a supported steady state, and it is never cloud-route acceptance evidence: record it as restart continuity, not as a cloud leg.

## Remote device over the cloud

1. Start both Test Homes with cloud connectivity and sign both Clients in.
2. Confirm both devices are online in the account inventory before dispatching anything.
3. On the observing Client, select the **remote** device and verify the route through keyed UI inspection plus bounded logs on the remote Home.
4. Send one message and verify it is served by the remote Agent, not by the local daemon.
5. Take the remote device offline and confirm the UI reports it as unavailable instead of rendering a stale list or claiming success; bring it back and confirm recovery without a Client restart.
6. Confirm the Client stayed responsive throughout the transition.

## Acceptance evidence

| Boundary | Required evidence |
| --- | --- |
| Route identity | The observing Client resolves the intended device; the serving Agent is named by bounded logs on its own Home |
| Dispatch | The remote Agent receives and serves the command; the local Agent does not |
| UI hydration | New keyed conversation body is rendered |
| Scope transition | Passive route indication changes without a Client restart |
| Stability | UI remains responsive with no crash or freeze |

Logs alone are insufficient; pair them with exact UI evidence. Never cite a same-device relay-only configuration as cloud evidence.
