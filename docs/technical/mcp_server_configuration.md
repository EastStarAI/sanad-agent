---
title: "MCP Server Configuration, Secrets, and Inspection"
description: "Daemon-owned MCP configuration, secret handling, inspection, OAuth, import/export, and runtime isolation architecture."
---

# MCP Server Configuration, Secrets, and Inspection

## Scope and authority

The local daemon is the only authority for MCP configuration persistence, secret storage, connection inspection, transport detection, OAuth state, and tool discovery. The client sends typed user intent and renders redacted daemon results. Cloud-origin turns may use locally configured MCP tools, but cloud/remote MCP management remains rejected.

Device and Workspace definitions remain independent. A Workspace definition with the same normalized name overrides the Device definition in the effective catalog.

## Form-first product contract

The primary flow is:

1. Choose **Remote server**, **Local command**, or secondary **Import configuration**.
2. Enter a typed draft. Remote defaults to `auto`; local uses `stdio`.
3. Test through the daemon. A successful STDIO test means launch, MCP handshake, and tool listing succeeded.
4. Review detected transport, authentication state, discovered tools, and selected tools.
5. Save through one daemon mutation authority.

Edit uses the same draft and review flow. Stored secrets are represented as `configured`; their values are never returned. Replacement and removal are explicit secret mutations.

The management page is card-first. Enabled state, connection health, authentication state, tool count, and scope are separate fields. Raw JSON is not a permanent pane.

## Typed configuration

Transports are `auto`, `stdio`, `streamableHttp`, and `sse`. `auto` is valid only for remote drafts and tries Streamable HTTP before SSE. A successful inspection returns the concrete transport.

Authentication is independent from transport:

- `none`
- `bearer`
- `oauth`
- `customHeaders`

`mixed` is not accepted by the new contract. Legacy entries are normalized conservatively during migration.

Configuration documents contain non-secret values and opaque secret references only. Runtime connection material is resolved inside the daemon immediately before use and is never included in snapshots.

## Secret ownership and migration

`mcp_secrets.json` under owner-protected Sanad Home is the single MCP secret owner. It uses the existing `SanadHomeBootstrap` atomic-write and owner-only permission boundary. Keys are opaque references scoped by configuration origin and server identity.

Secrets include bearer tokens, secret custom-header values, secret environment values, OAuth access/refresh tokens, and OAuth client secrets. OAuth client IDs, endpoints, ordinary headers, and ordinary environment values are non-secret metadata.

Migration is idempotent:

1. Read the legacy configuration without rewriting it.
2. Extract recognized legacy secret values and atomically merge them into the secret owner.
3. Verify the stored references can be resolved.
4. Atomically write a redacted configuration containing references.
5. Keep the original configuration untouched if any secret write or verification fails.

Repeated migration sees references and performs no duplicate mutation. Missing or partial legacy files remain valid. Deleting or replacing a server does not remove a secret unless the mutation explicitly requests secret removal.

## Custom headers

Header names must be valid HTTP token names. Empty names, duplicates (case-insensitive), CR/LF in names or values, pseudo-headers, `Host`, `Content-Length`, `Transfer-Encoding`, `Connection`, `Proxy-Authorization`, and `Proxy-Authenticate` are rejected. `Authorization` is reserved for the typed Bearer/OAuth modes.

Each allowed custom header is explicitly secret or non-secret. Secret values are stored by reference; non-secret values remain in configuration. Errors identify the field but never echo values. Snapshots, export, logs, and errors redact all secret values.

## Import, export, and Advanced JSON

Import accepts bounded UTF-8 JSON in these shapes:

- `{ "mcpServers": { "name": { ... } } }`
- a bare name-to-config map
- one server object with an explicit `name`

`mcp_servers` and transport `type` are recognized aliases. A preview returns typed servers, field warnings, and unsupported fields without persistence. Duplicate normalized names, contradictory command/URL transports, unsupported secret-bearing shapes, invalid headers, malformed input, and oversized input fail before mutation. Saving imports is a separate reviewed mutation and never replaces a whole Device or Workspace document.

Export is server-scoped or explicitly selection-scoped and ecosystem-compatible. It omits secret values and OAuth token material. It may include a non-credential `configured: true` marker only in Sanad preview metadata; exported ecosystem credentials are omitted entirely and cannot be replayed.

Advanced JSON is one-server-only. Its initial canonical JSON is redacted. Preview validates and returns the typed candidate plus a field diff and revision fingerprint. Save requires that preview fingerprint, rejects stale edits, and routes through the same single-server mutation. It cannot read or replace a root document or another scope.

## Inspection and OAuth states

Inspection returns:

- `success`
- concrete `transport` when detected
- `auth_state`
- discovered `tools`
- a redacted actionable error

OAuth states are `pending`, `authorizationRequired`, `approved`, `error`, `cancelled`, and `expired`. A flow ID is opaque and non-secret. The daemon owns discovery, PKCE, registration, callback resources, token exchange, refresh, cancellation, and expiry. The client receives only flow ID, authorization URL, state, tools, and redacted errors. Inspection and OAuth never persist server configuration without a separate explicit mutation.

All connection attempts, child processes, callback listeners, and polling resources use bounded timeouts and cleanup on success, error, timeout, cancellation, or late results.
