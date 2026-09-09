---
title: "Hosted Services Boundary"
description: "Ownership and compatibility boundary between the open-source Sanad Agent clients and EastStar AI hosted services."
---

# Hosted Services Boundary

## Ownership

The open-source repository owns the local Dart daemon, Flutter clients, local state, client-side authentication adapters, public wire behavior, and local-only execution. EastStar AI hosted services own the Portal, cloud Gateway, account and device inventory, cloud relay, hosted persistence, and their operational infrastructure.

The public project consumes hosted services only through documented HTTPS and Socket.IO contracts. It does not import Backend or Portal source, migrations, server configuration, or deployment code.

## Supported Operating Modes

### Local-only

The desktop client communicates directly with the local daemon. Dependency resolution, development, tests, provider setup, workspace execution, and supported local conversations do not require hosted-service source code. Cloud connection can be disabled without creating a replacement Gateway or Portal.

### Cloud-connected

The official Portal brokers user authentication, token refresh, and logout.
Authenticated clients and daemons connect to the official Gateway for remote
device inventory and event relay. Public source runs, including primary
checkouts, independent clones, linked worktrees, and modified forks, select the
Production profile by default and use the hosted service exactly as ordinary
users. A private Backend/Portal integration build must inject its hosted
endpoint overrides explicitly; selecting a non-local environment name alone
continues to use the official Production endpoints.
`--no-cloud` disables hosted communication while preserving direct local use.

Source availability and service availability are separate guarantees: the
client source is MIT licensed, while use of the hosted service remains subject
to its published service and privacy terms. Source possession, build provenance,
or a Production URL grants no trust. Hosted services authenticate and authorize
every client and daemon, isolate users, validate payloads, and apply operational
limits server-side.

## Public Authentication Surface

Open-source clients use flow-specific Portal contracts:

- Flutter: `POST /auth/client/transactions` and `POST /auth/client/token` with
  S256 PKCE and a registered callback.
- Headless Agent: `POST /auth/device/transactions` and
  `POST /auth/device/token` with P-256 proof-of-possession.
- User session maintenance: `POST /auth/refresh` and `POST /auth/logout`.

Provider-specific login implementation remains hosted. Generic bearer-result
polling is unsupported. Access, refresh, device, PKCE, proof, and provider
credentials never become public configuration and follow the secret boundaries
in `client_authentication.md`.

Remote device creation returns one initial pairing token to the authenticated
client. The public agent persists that token only with a distinct durable
token it generates locally, then sends both over the Gateway registration
contract. The hosted Gateway atomically binds the hardware identity and
replaces the initial token hash with the durable token hash. A retry may present
the same pair after a lost response; ordinary inventory never returns either
credential, and a consumed initial token cannot authenticate again.

## Realtime Surface

Local communication uses the daemon's local WebSocket/HTTP boundary. Cloud communication uses the authenticated Socket.IO Gateway. Canonical device commands, device events, session state, queue and steer behavior, recovery, and inventory behavior are specified in `communication_protocols.md` and the focused technical pages it links.

The public wire specification is authoritative for client compatibility. Hosted implementation details, database schemas, queueing infrastructure, and deployment topology are not part of the public contract.

Command relay must bind the authenticated User to the target device before
forwarding `device_command`. Relayed command payloads are not a hosted
persistence surface. Remote Agent update, restart, workspace, and MCP
management in Task 82 use this relay into daemon-owned handlers; they must
not write MCP configuration through hosted REST `/api/mcp`. See
[Remote Device Control Threat Model](remote_device_control_threat_model.md).

## Compatibility

Hosted services add backward-compatible support before a public client begins depending on new protocol behavior. A public release identifies the behavior it consumes. Breaking removal is a separate, reviewed transition and must not be coupled to an unannounced server deployment.

Client or daemon behavior that depends on the cloud must fail explicitly or degrade to its documented local behavior when the service is unavailable. Hosted-service source access is never a recovery requirement.

## Automated verification boundary

Unit, widget, integration, E2E, and required CI checks never authenticate to or
send fixtures, credentials, or test traffic to Production. They use injected
mocks/fixtures or explicit local-only execution. A Production cloud smoke test
is manual, explicit, bounded, non-destructive, and never a required check.

## Configuration and Secrets

Public client configuration may include official service URLs and platform
application identifiers. Privately operated Development and Staging endpoint
values remain owned by private deployment automation and are injected when it
builds an exact public commit. Version `1.0.0` does not ship external telemetry
or push configuration. Public configuration never includes OAuth client
secrets, signing private keys, server environment values, deployment
credentials, or user tokens.

Provider credentials and Sanad identity tokens are runtime user data stored outside Git. Diagnostics redact credential-shaped fields before serialization.
