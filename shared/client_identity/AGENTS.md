# Client Display Identity Contract

## Scope
This contract applies to `shared/client_identity/`.

## Ownership
- Own the provider-neutral deterministic short reference shared by the Agent and Client presentation layers.
- Prefer authenticated `client_instance_id`; use account `client_session_id` only as a namespaced legacy fallback.
- References are display-only correlation metadata. They never grant authority, select recipients, or replace canonical Client/session identity.
- Never expose the raw source identifier or encode reversible source fragments.
- Keep output bounded, uppercase, and stable across supported Dart platforms.
