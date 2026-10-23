---
title: "User Secret Management Protocol"
description: "Unified local/cloud protocol commands, envelopes, error codes, and redaction invariants for device-owner user secret management."
---

# User Secret Management Protocol

> **Owning task:** `docs/plans/tasks/140-client-secrets-screen.md`
> **Product UX:** `docs/product/settings_hub.md`
> **Authority specification:** `docs/technical/execution_trust_and_permission_authority.md` §10

## 1. Goal and Overview

This protocol allows the device owner to manage credentials used by the Agent in commands (e.g., database passwords, API tokens) through a dedicated Settings screen (**Settings → Privacy & Security → Secrets**), bypassing the LLM entirely.

The protocol is strictly **write-only**:
- Secret values travel in exactly one direction: into the OS credential vault (`custom:` namespace).
- No command, response, event, broadcast, log, error message, cache, or database row ever exposes a stored secret value or its prefix.
- There is **no reveal** mechanism, ever—not for the user, not for the model, and not for technical support.

---

## 2. Transport Invariant

Commands travel within the standard `device_command` envelope and resolve transport per request in `DeviceConnectionCoordinator`:
- Both direct Local Gateway loopback and Cloud Gateway relay routes use the exact same command family, payload shapes, and response envelopes.
- No client-side feature branches on connection type or transport scope.
- Every command carries a canonical `request_id` for response correlation.

---

## 3. Authority and Permission Gate

Secret management is strictly **device-owner authority only**:
- Every ingress transport stamps `command_authority` on the command payload (`owner` for authenticated loopback and authenticated cloud sockets; `unverified` otherwise).
- Any request lacking `owner` authority is refused immediately with error code `permission_denied` and mutates nothing.
- Model tools and tool execution paths cannot invoke this protocol.

---

## 4. Commands and Event Contracts

### 4.1. `secrets.list`

Lists non-secret metadata for all stored user secrets.

- **Wire Command:** `secrets.list`
- **Response Event:** `secrets.list_result`
- **Request Payload:**
  ```json
  {
    "request_id": "req-123"
  }
  ```
- **Response Payload:**
  ```json
  {
    "request_id": "req-123",
    "secrets": [
      {
        "name": "DATABASE_PASSWORD",
        "description": "Staging database password",
        "source": "user",
        "created_at": "2026-10-23T08:12:00.000Z",
        "updated_at": "2026-10-23T09:40:11.000Z"
      }
    ],
    "truncated": false
  }
  ```

#### List Projection Semantics
- **Structurally value-free:** The projection schema contains no value field.
- **Repair-on-read:** If a secret exists in the vault but has no row in `user_secret_metadata` (e.g. stored before Task 140 or via composer card), `UserSecretCatalog.list()` inserts a row with `source = agent_request`, `description = null`, and `created_at = updated_at = now`. A returned entry never carries null timestamps.
- **Prune-on-read:** Any metadata row whose name no longer exists in the vault is pruned during the read.

---

### 4.2. `secret.set`

Adds a new secret or replaces the value of an existing secret.

- **Wire Command:** `secret.set`
- **Response Event:** `secret.saved`
- **Request Payload:**
  ```json
  {
    "request_id": "req-456",
    "name": "DATABASE_PASSWORD",
    "value": "super_secret_password_here",
    "description": "Staging database password"
  }
  ```
- **Response Payload:**
  ```json
  {
    "request_id": "req-456",
    "name": "DATABASE_PASSWORD",
    "description": "Staging database password",
    "source": "user",
    "created_at": "2026-10-23T08:12:00.000Z",
    "updated_at": "2026-10-23T09:40:11.000Z"
  }
  ```

#### Set & Rotation Semantics
- `value` appears in the request payload and nowhere else. It is excluded from the response envelope, logs, and error text.
- Replacing is write-only: the Client replace form starts empty and never reveals or reads the old value.
- Passing `null` or whitespace-only `description` clears the description column.
- Write ordering is vault-first (verified readback) then metadata upsert with `source = 'user'` and updated `updated_at`.
- Upon successful mutation, emits the family broadcast `secrets.changed` with `{ "name": name, "change": "set" }`.

---

### 4.3. `secret.delete`

Permanently deletes a stored secret.

- **Wire Command:** `secret.delete`
- **Response Event:** `secret.deleted`
- **Request Payload:**
  ```json
  {
    "request_id": "req-789",
    "name": "DATABASE_PASSWORD",
    "confirm": true
  }
  ```
- **Response Payload (when found and deleted):**
  ```json
  {
    "request_id": "req-789",
    "name": "DATABASE_PASSWORD",
    "status": "deleted"
  }
  ```
- **Response Payload (when name not found in vault):**
  ```json
  {
    "request_id": "req-789",
    "name": "DATABASE_PASSWORD",
    "status": "not_found"
  }
  ```

#### Deletion Semantics
- Deletion requires explicit confirmation: `confirm: true` must be present and boolean true; otherwise the command is refused as `invalid_request`.
- Removes the secret from the OS vault and deletes the metadata row from SQLite.
- Emits the family broadcast `secrets.changed` with `{ "name": name, "change": "deleted" }` only when `status == "deleted"`. No broadcast is emitted if the name was not found.

---

## 5. Broadcast: `secrets.changed`

To prevent multiple connected clients from displaying stale secret rows, a successful mutation triggers a family broadcast:

- **Event:** `secrets.changed`
- **Delivery Policy:** `platformFamily(PlatformFamily.sanadClient)` via `GatewayManager.publishFamilyEvent`
- **Payload Schema:**
  ```json
  {
    "name": "DATABASE_PASSWORD",
    "change": "set"
  }
  ```
  *(where `change` is `"set"` or `"deleted"`)*

Clients receiving `secrets.changed` refresh their secret list without displaying or caching stale data.

---

## 6. Error Handling and Error Codes

Failed commands return a standard error envelope:
```json
{
  "type": "event",
  "event": "error",
  "request_id": "req-123",
  "payload": {
    "request_id": "req-123",
    "code": "invalid_secret_name",
    "message": "DATABASE_PASSWORD is not a valid environment variable name."
  }
}
```

The error `message` names the secret and the failure reason, and **never contains the submitted value, a prefix of it, or its length in characters**.

| Code | Trigger Condition |
|---|---|
| `permission_denied` | Request received from a transport or caller lacking `owner` authority. |
| `invalid_request` | Unknown field in payload, wrong type, missing `name`, missing `confirm: true` on delete, or `description` > 256 characters. |
| `invalid_secret_name` | Name does not match `^[A-Za-z_][A-Za-z0-9_]{0,63}$`. |
| `reserved_secret_name` | Name is a protected system variable (e.g. `PATH`, `LD_*`) or Sanad variable (e.g. `SANAD_*`, `OPENAI_API_KEY`). |
| `invalid_secret_value` | Submitted value is empty, exceeds `UserSecretVault.maxValueLength` (16,384 characters), or contains a redaction sentinel (`[REDACTED:...]`). |
| `vault_unavailable` | The platform credential vault is unavailable or failed to store the value. |
| `internal_error` | Database repository read/write failure. |

---

## 7. Security and Cloud Relay Invariants

1. **Inbound Only:** Secret values travel inbound only from the Client to the Agent daemon within the `device_command` envelope over TLS / WSS.
2. **Cloud Relay Non-Persistence:** The Sanad Gateway relays the command envelope to the target daemon without logging or persisting the command payload.
3. **Agent Logging Boundary:** Daemon logs record the secret name, command type, and outcome code only. Payloads are never serialized to string or logged.
4. **Redaction Sentinel Rejection:** A submitted value matching `[REDACTED:<NAME>]` is rejected on both Client and Agent, ensuring displayed redaction masks cannot become stored secrets.
5. **No Model Exposure:** Secret values are never part of LLM prompts, tool arguments, tool outputs, message history, or request dumps.
