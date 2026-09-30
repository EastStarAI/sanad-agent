# Agent Plugins Contract

## Scope
This contract applies to `agent/lib/plugins/`.

## Ownership
- Plugins provide generic lifecycle hooks around engine execution only.
- `PluginManager` owns registration, initialization, hook ordering, failure isolation, and disposal.
- `BasePlugin` defines the lifecycle contract; implementations must not bypass runtime, persistence, capability, or interface owners.
- Plugins must not become a second conversation-history owner or perform context compaction.

## Lifecycle
- Initialize each plugin once through composition and dispose it with the owning runtime.
- Preserve deterministic hook order around pre/post model execution.
- Contain plugin failures so an optional plugin cannot terminate the daemon or corrupt committed runtime state.
- Do not execute terminal delivery, durable admission, provider credential mutation, or platform routing from plugin hooks.

## State Safety
- Plugins receive bounded inputs and return explicit transformations or side effects through their declared hook.
- Do not retain mutable references to engine history or active-run state.
- Do not log secrets, raw sensitive tool payloads, or recovered input.
- Plugin-specific architecture belongs in `docs/`; operational enablement belongs in skills/configuration documentation.
