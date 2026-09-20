---
title: "Device Runtime Settings Protocol"
description: "Unified local/cloud protocol commands, validation, persistence, and secret-handling rules for device settings."
---

# Device Runtime Settings Protocol

> **Owning task:** `docs/plans/tasks/34-settings-hub-and-device-runtime-settings.md`
> **Product UX:** `docs/product/settings_hub.md`

## Transport invariant

The client sends all feature commands with a target `DeviceConfig` through `DeviceCommandClient`. `DeviceConnectionCoordinator` resolves the current local or cloud route at request time. Settings, Providers, MCP, Skills, and Workspace features must not select a transport directly.

Both transports carry the same command and response envelopes with `request_id` correlation.

## Commands

### `device.settings.get`

Returns `device.settings.snapshot` with:

- Cloud Connection enabled and externally-managed state.
- Computer Use enabled, externally-managed, and OS-permission state.
- Web Search provider, Serper configured state, and management flags.
- Provider Auto Failover enabled and externally-managed state.

The snapshot never includes `SERPER_API_KEY` or another stored credential.

### `device.settings.update`

Accepts a `changes` map containing only:

- `cloud_connection_enabled`
- `computer_use_enabled`
- `web_search_provider`
- `serper_api_key`
- `provider_auto_failover_enabled`

The agent validates the complete request before a single environment-file mutation. Unknown fields, invalid types, invalid search providers, and process-environment-owned values fail without a partial write.

The response is `device.settings.updated`. A Cloud Connection update includes `restart_required=true`; after the response is emitted, the agent schedules the supervised restart. Web Search and Provider Auto Failover update live without restart.

## Runtime behavior

Web Search resolves `WEB_SEARCH_PROVIDER` and `SERPER_API_KEY` when each search executes. Provider Auto Failover updates `RuntimeRecoveryService.autoFailoverEnabled` immediately. Cloud Connection persists `ENABLE_GATEWAY` through the current `EnvFileService` path before the controlled restart.

## Resource inventories

`list_skills` returns `skills_list`. With no workspace id it contains device/user scope only. With a workspace id it returns the agent-owned merged inventory including origins and shadowing.

MCP uses the existing command family. A request without workspace id is device-only. A request with workspace id returns device, workspace, and effective sections; the workspace definition wins on canonical-name collision.

Remote update, restart, workspace, and MCP management share the typed contract in [Remote Device Control Protocol](remote_device_control_protocol.md).
