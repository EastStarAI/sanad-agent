---
title: "Plan 29 Provider Setup Regression Matrix"
description: "Regression coverage targets for the instance-first provider setup runtime."
---

# Plan 29 Provider Setup Regression Matrix

## Scope

This matrix tracks the regressions that must stay covered while Plan 29
provider instances evolve across the daemon, CLI, and Flutter client.

## Active Regression Targets

| Area | What must hold |
|---|---|
| `model.refresh` acking | Client requests must ignore the non-terminal `started` event and complete only on `updated` or `failed`. |
| First onboarding instance | The first created instance becomes the default automatically unless another default was chosen explicitly. |
| Runtime readiness | `ready` requires credential + selected model + successful endpoint/model discovery for the current revisions. |
| Model picker readiness | Client UI reads readiness from `model.snapshot.instances[].status`, not from cache presence. |
| Model id normalization | `model.snapshot` and `model.recent.list` expose instance-local ids only; they must not leak redundant provider prefixes or Gemini's `models/` path segment into the picker UI. |
| Responsive embedding | Long provider steps scroll without overflow in a bounded setup overlay, while Settings keeps its outer page scroll and renders the same shared flow without a fixed height. |
| Derived authentication | Production templates with one advertised method show no Authentication Method selector, and the agent rejects methods not advertised by the selected template. |
| Dormant local rate limit | Provider forms show and send no request-limit value; all template defaults, new instances, and upgraded non-zero rows resolve to `0` while compatibility schema and DTOs remain. |
| Canonical device code | A provider-supplied code such as `ABCD-1234` is displayed unchanged, never as `ABCD--1234`, has an adjacent copy button that copies the canonical value through the global Success/Error Toast system without a SnackBar, and browser copy does not claim a successful open before launch success. |
| Protocol display names | Add and Edit both render `openai_compatible` as `OpenAI API Compatible` and `anthropic_compatible` as `Anthropic API Compatible`; mutations keep the canonical wire value. |
| Visible auto failover warning | Add and Edit always render Auto Failover without an Advanced disclosure; enabled switches use the warning/error color and persistent red copy without a colored background explains automatic use after another provider fails. |
| Credential summary mapping | Canonical daemon fields `configured` and `masked_key_hint` render a stored API key. OAuth approval and lazy reads derive optional `account_label` (`email` → `preferred_username` → `upn` → `name`) and `account_name` (`name`) from JWT claims without treating them as authorization state; malformed, opaque, blank, or non-string claims remain absent. Provider cards and Edit render the label plus a distinct name, suppress duplicate name/label text, and retain Connected rather than Disconnected when identity is unavailable. Raw tokens never cross the summary boundary; legacy `has_secret` and `masked_secret` remain read-only migration aliases. |
| Existing API-key replacement verification | Adding or replacing an API key on an existing instance runs the canonical connection test before reporting success. A successful test reloads the authoritative ready state; a failed test keeps Edit open, does not leak provider error details, and states that the key was saved but not verified. The mutation atomically replaces the targeted UUID record and prunes secret records whose UUIDs no longer exist in authoritative provider metadata. |
| Canonical connection-test result | Provider-card Test treats daemon `success: true` as success for Codex/OAuth and API-key instances; it does not inspect an absent presentation `status` field. |
| Single API-key entry | API-key setup writes the details-step key to the newly created instance, skips the legacy second key form, and creates the instance without a default model before discovery. |
| Provisional draft ownership | Back then Continue reuses one instance UUID and restores controller-owned input; confirmed Discard removes only that UUID, while existing edited instances are never eligible for setup cleanup. Draft cards provide Resume setup and Delete. |
| Model discovery recovery | Failed live discovery remains visibly failed with safe copy, Retry reuses the same instance, Add Model exposes one validated identifier field, cached suggestions are labeled, Back saves no model, a late refresh cannot reopen selection after Back, and a failed Confirm preserves manual input. |
| Fixed step actions | Continue, Save changes, Back, Cancel, Confirm Model, Retry, Add Model, and Use Model stay visible without body scrolling in the bounded provider-required overlay; the same views use the Settings outer scroll without nested-scroll overflow. |
| Read-only Edit connection | Every Edit view shows selectable Base URL and a friendly Protocol display name, uses a subdued theme-aware gray border rather than a bright white outline for all read-only values, sends neither field in metadata mutations, keeps credential Replace/Remove or OAuth Reconnect explicit, exposes Change Model and the deletion danger zone, and confirms before abandoning dirty edits. Editing an existing OAuth/device-code/loopback instance saves metadata without triggering re-authentication; the edit returns to the configured list and OAuth restarts only through the explicit reconnect action or during first-time setup. |
| Non-destructive card operations | Test, Make Default, Delete, and reconnect keep the configured list rendered, disable only the targeted card action, and show target-scoped success/failure feedback. Default deletion includes a readiness warning. |
| OAuth launcher and cancellation truth | Device Code auto-launches once per session; Open/Re-open copy accepts results only for the active session, canonical code text is unchanged, and Cancel remains available through pending, expired, and error states. An in-flight poll that completes after Back, Cancel, or Discard cannot revive or advance the abandoned flow. |
| Shared CLI/client cache | CLI live discovery writes through `ProviderModelCacheService` so `model.snapshot` and CLI "Show Cached Models" see the same data. |
| Shared CLI/client recent | CLI selections record through `RecentModelSelectionService` so the Flutter picker sees the same recent models. |
| Legacy removal | New work must use `provider.templates.list`, `provider.instances.list`, `provider.instance.*`, `provider.credential.update`, `model.snapshot`, `model.refresh`, and `model.recent.*` only. |

## Current Automated Coverage

| Layer | Coverage added/updated in this change |
|---|---|
| Agent unit tests | Readiness promotion waits for verified cache state; OAuth identity extraction covers claim priority, invalid values, lazy stored-record enrichment, summary mapping, and instance-keyed approval persistence. |
| Agent interface tests | Templates/instance commands and `model.snapshot` status are exercised through `SanadProtocolBridge`. |
| Client bloc/widget tests | Template loading no longer relies on legacy fallback, snapshot DTOs carry instance `status`, credential DTOs preserve `account_label`/`account_name`, OAuth cards and Edit render both distinct identity values, and the shared flow is covered in bounded-overlay and unbounded-Settings layouts. |
| CLI tests | `sanad setup list` / `remove` assert the instance repository is the source of truth. |
