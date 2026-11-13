---
title: "Provider Account Usage Limits"
description: "Product behavior for instance-scoped provider usage windows, freshness, errors, and reset-credit controls."
---

# Provider Account Usage Limits

## Purpose

Users need to understand account-level provider limits without leaving Sanad or
confusing those limits with the token usage of one conversation. Usage belongs
to a configured provider account, identified by its provider instance, and may
be available for OAuth or API-key providers when that provider exposes a safe
account-usage API.

The supported accounts are ChatGPT through the `openai-codex` provider template
and OpenCode Go through the `opencode-go` template. ChatGPT is an OAuth account;
OpenCode Go is an API-key subscription with 5-hour (Session), Weekly, and
Monthly windows and no reset credits. The experience remains capability-driven
so future providers can add support without a client catalog change. This
rollout order is about account-usage capability only and does not describe the
provider setup list, whose order follows the provider registry.

## Placement and loading

`Settings → Device → Providers → Configured Providers` shows the existing
provider cards immediately. A supported card includes a collapsed
`Usage & limits` disclosure. Capability discovery and usage loading happen
after the configured instances render and never block provider metadata,
readiness, or actions.

Unsupported accounts have no disclosure. They do not show an empty panel or an
error. A temporary usage failure affects only this disclosure and never changes
the provider's readiness.

## Snapshot presentation

The expanded disclosure may show:

- plan name, when supplied;
- one row for each supplied Session, Weekly, or Monthly window;
- safe provider details, when supplied;
- the last update age and a per-account Refresh action.

Window labels are localized from the typed window (Session, Weekly, Monthly).
An unknown future type falls back to the daemon's label instead of disappearing.

There are no placeholder rows. For example, a ChatGPT response containing only
Weekly and Monthly displays exactly those two rows.

Each window prioritizes the remaining value, such as `58% remaining`, and shows
the used value as secondary information, such as `42% used`. Its progress bar
represents consumption. Reset timing is rendered relative to the user's local
time zone, with the full local time available as a tooltip.

## Freshness and recovery

A successful snapshot remains fresh for one minute. Returning to the provider
surface during that interval reuses it without another usage request. After one
minute, Sanad keeps the stale snapshot visible while refreshing it in the
background. There is no periodic polling.

Refresh targets only the selected provider instance and is disabled while that
instance already has a request in flight. A failed background refresh preserves
the previous values and adds a concise Retry message. Authentication failures
show a sign-in-oriented message. Device switches, account removal, disposal,
and late responses cannot move usage between accounts or devices.

## Credential recovery

`auth_required` means the account's credential needs user action. Account
instances offer the same `Reconnect` flow as the instance form. API-key
instances offer `Update API key`, which opens the instance edit form, because an
OAuth reconnect cannot repair a static key. Neither action changes the provider
card's readiness.

## Reset credits

When the daemon reports at least one reset credit, the expanded section shows the count and **Reset limits**. Exhausted limits use a normal confirmation. Non-exhausted limits require a second warning returned by the daemon and an explicit **Reset anyway** action. The button is disabled during execution. Sanad never subtracts credits or changes percentages optimistically: it replaces the card only with the provider snapshot returned after reconciliation. If reset succeeds but refresh fails, the success remains visible and the existing values remain stale with a retry path.
