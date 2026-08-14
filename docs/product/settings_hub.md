---
title: "Settings Hub"
description: "Information architecture, scope semantics, and device-management UX for Sanad's unified Settings destination."
---

# Settings Hub

> **Owning task:** `docs/plans/tasks/34-settings-hub-and-device-runtime-settings.md`
> **Protocol:** `docs/technical/device_runtime_settings_protocol.md`

## Purpose

Settings is the single place to manage the Sanad client, account, installed agents, and agent-owned workspace resources. A device represents one installation of Sanad Agent. Local and cloud are connection routes to the same device protocol, not different device feature sets.

## Navigation

The primary Settings navigation contains Profile, General, and **Sessions & Devices**, followed by devices. Sessions & Devices is account-scoped: Client Sessions shows the current Client marker, normalized platform/app details, authoritative `Online` or `Offline` status, independent Last active time, and confirmed revoke. A presence-registry outage is shown as `Status unavailable` while retaining the last snapshot; it is never presented as Offline. Connected Agents reuses the existing device inventory, opens the selected device's Overview, and offers account revoke only for an account-backed device. Per-row operations are single-flight, and unknown outcomes refresh rather than claiming success. A confirmed revoke of the current Client completes the normal logout flow.

The remaining device navigation follows these rules. On desktop, the current local device is pinned first; remaining devices are oldest-to-newest. On desktop, the current local device is pinned first; remaining devices are oldest-to-newest. Web and mobile show the complete device list oldest-to-newest. Selecting a device reveals Overview, Providers, MCP Servers, Skills, and its Workspaces. Up to six workspaces are visible initially; Show all and Show less expand or collapse the remainder.

Selecting a device changes only the Settings inspection target. The conversation device changes only through Set as active in Overview.

A workspace opens one detail page with Overview, MCP Servers, and Skills tabs. It does not create a nested sidebar. The conversation sidebar exposes a hover-only settings gear that deep-links to this page with the exact inspection device and workspace selected. Workspace Overview owns **Rename Workspace** for the Sanad display name and **Change Path** for reconnecting the same stable workspace identity to a different folder; these are separate actions and neither changes the workspace UUID.

Compact layouts move the same navigation into a drawer. Destinations and capabilities remain identical to the wide layout.

## Scope presentation

- Device MCP lists and edits only device-level servers.
- Device Skills lists only user-level skills discovered by the agent.
- Workspace MCP shows Device and Workspace origins. A same-name workspace definition is effective and the inherited device definition is identified as overridden.
- MCP management is card-first: each server presents enabled, connection, authentication, tools, transport, and origin independently. Add and Edit share a typed Remote/Local form with structured arguments, environment variables, headers, configured-secret replacement, real daemon testing, and tool review.
- Import is a secondary preview-first action. Export always excludes credentials. Advanced JSON is available per server only and requires validation plus a reviewed diff before Save; no raw JSON pane appears in normal management.
- Workspace Skills shows Device and Workspace origins plus active and shadowed state returned by the agent.

## Device Overview

Overview presents identity, online and active state, current route, version, explicit activation, supported runtime actions, and a separate danger area.

The displayed device name includes an edit action for account-backed devices. Rename opens a focused dialog seeded with the current name, rejects blank or unchanged input, and keeps the dialog open with an actionable error until the authoritative account inventory accepts the mutation. A merged local/cloud entry edits the cloud-backed name while retaining its stable local UI identity. A local-only placeholder does not show rename because it has no durable account record.

Cloud Connection is shown only on a currently local route. Computer Use includes OS permission state. Web Search supports DuckDuckGo and Serper while exposing only whether a Serper key is configured. If the agent daemon reports an unknown provider value (e.g. a value the client build has not shipped yet), the selector quietly renders the empty state instead of tripping Flutter's `DropdownButton` "exactly one item" assertion. Diagnostics are deferred.

## Providers

The existing provider setup flow remains the provider editor. Current provider templates advertise one authentication method, so setup derives it and does not display an authentication-method selector. API-key setup collects the key once in Provider details, stores it on the newly created provisional instance, and proceeds directly to model discovery; Default Model is selected only in the model step. Local request-rate limiting is dormant: the compatibility field remains in the runtime, but Settings does not expose a Rate Limit control and every instance is unlimited. Device codes are displayed exactly as supplied by the provider with an adjacent copy action. Copy success and failure use the application's global Success/Error Toast system—never a SnackBar—and the verification-page copy must not claim that a browser opened until a launcher attempt actually succeeds.

During new-provider setup, Back preserves the current details and reuses the same provisional provider identity. Cancel after that identity exists asks `Discard provider setup?`; Discard removes only the provider created by the current attempt. Cancel while editing an existing provider never deletes it. If cleanup fails, the incomplete provider remains visible in the configured list instead of becoming a hidden orphan. Configured draft cards expose Resume setup and Delete instead of hiding incomplete work.

Model discovery has explicit loading, loaded, failed, and manual-entry states. A failed live request stays visibly failed and offers Retry, Add Model, and Back; fallback names may appear only as `Cached suggestions`. Add Model asks for the exact model identifier and persists it only after Confirm Model. Save failures keep that manual input visible.

Edit keeps Base URL and Protocol visible as selectable read-only connection identity. Read-only connection, credential, and current-model values use a subdued theme-aware gray border rather than a bright white outline. Protocol wire values are formatted consistently in Add and Edit (`openai_compatible` as `OpenAI API Compatible`, `anthropic_compatible` as `Anthropic API Compatible`) and raw identifiers are never shown as display copy. Display Name, credential actions, and auto-failover remain editable, while API-key replacement/removal and OAuth reconnect are explicit actions. Stored API-key and connected-account presentation reads the daemon credential summary's canonical `configured`, `masked_key_hint`, `account_label`, and `account_name` fields, so a working configured provider is never shown as Not set or Disconnected. OAuth provider cards and Edit show the account email/username when available and show the account name separately only when it differs; providers whose tokens expose no usable identity claims retain the neutral Connected fallback. Auto-failover is always visible in both Add and Edit rather than hidden behind Advanced; its switch uses the warning/error color while enabled, and persistent red warning copy without a colored background explains that Sanad may automatically use this provider when another provider fails. Provider-card Test, Make Default, Delete, and reconnect feedback is scoped to the target card and never replaces the configured list with a loading page. Test results consume the daemon's canonical Boolean `success` field so a successful Codex model refresh is presented as success. Deleting the default provider includes a routing-readiness warning.

Provider details, OAuth, and model selection use a persistent action footer in bounded overlays, with only their body scrolling. The same shared views remain in normal document flow when Settings owns the outer scroll.

Provider Auto Failover is a device-level master switch. Turning it off preserves each provider instance's failover preference and disables those instance controls until the master is enabled again.
