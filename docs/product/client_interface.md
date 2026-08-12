---
title: "Sanad Client Interface"
description: "Current user experience for devices, workspaces, conversations, providers, permissions, and active agent interactions."
---

# Sanad Client Interface

Sanad Client is the Flutter interface for local and remote Sanad Agent
devices. It uses the same interaction model on desktop, mobile, and web while
adapting navigation and controls to the available screen width.

## Device context

The selected device is the top-level context for the client. Device management
lets the user:

- switch between paired computers and servers;
- see connection and availability state;
- add a named remote device, then copy vertically stacked macOS/Linux and
  Windows command cards styled as compact code editors;
- rename or remove a registered device;
- retry, repair, start, or restart the applicable connection or local service.

Changing the selected device changes the workspaces, conversations, provider
configuration, and runtime state displayed by the client. It does not create a
new conversation.

The compact Home gateway/status bar is a native-desktop surface. Web and mobile
never render it, regardless of browser or viewport width. Its gateway and
optional worktree badge consume only the expandable leading region; desktop
mode and `SanadAgent` remain anchored to the trailing edge.

Desktop onboarding is local-first: installing the agent on the current computer
is the primary card action, while signing in or connecting a remote device is a
secondary text action. Mobile and web never offer local installation. When an
authenticated mobile or web user has no registered devices, onboarding presents
a `No devices connected` empty state with `Add a Remote Device` as its primary
action.

When an empty device inventory is still being requested, the sidebar identifies
that request as loading rather than claiming that no devices exist. If the
request settles successfully, times out, or fails without returning a device,
the header changes to the settled `No devices` state. Local inventory events do
not prematurely end a cloud inventory request, and signing out does not leave a
stale request spinner behind.

## Conversation navigation

For the selected device, the navigation surface displays:

1. workspaces;
2. the conversations that belong to each workspace;
3. conversations that are not attached to a workspace.

Each section has independent pagination and cache-first loading. Cached content
remains navigable while a refresh is running or while the remote device is
temporarily unavailable. Recent user activity moves a conversation to the top
of its section without losing the current selection or scroll position.

On wide desktop and tablet layouts, navigation appears as a persistent,
resizable sidebar. The resize target follows the sidebar's visible edge,
including the macOS shell margin, and the selected desktop width is restored
from local client preferences on the next launch. On mobile and narrow layouts,
it becomes a drawer that closes after a destination is selected.

Opening a conversation with active work shows its latest event so current
progress is immediately visible. An idle conversation resumes from the event
where the user last stopped after manually scrolling. If no saved reading
position exists, it opens at the latest user message; a missing saved event uses
the same fallback. Starting a new user turn discards the older reading position.
The first message in an empty timeline stays near the top. In an existing
timeline, a newly sent message does not move the view when it is already fully
visible; if the composer obscures it or it falls below the viewport, the client
reveals it by only the necessary distance and without animation.

Short conversations always remain aligned near the visible top; opening active
work never leaves an empty upper page with content attached to the composer.
Long active conversations may open at their latest event. New agent events enter
with a short visual fade-and-slide transition. If the user is already actively
following the tail, the page follows that new event with a brief smooth scroll;
otherwise the event animation does not move the reading position. Opening active
work at the tail or manually returning to the bottom grants follow eligibility. While following, a growing thinking, reasoning, or
final-answer bubble moves the page only by the amount needed to keep its bottom
above the composer. Scrolling away revokes eligibility immediately, after which
streaming growth and later activity preserve the reading position.

## New conversations

New Conversation begins as an unsaved composition surface. The user chooses a
device and workspace before sending the first message. A persistent session is
created only after the first accepted send.

The same composer is used for a new conversation and an existing session. It
preserves per-device drafts and the selected workspace, provider, model, and
thinking mode. A first-time user with no thinking preference starts at
`balanced`, while saved returning-user choices remain unchanged. When the
runtime has an authoritative provider/model route, the model selector is never
left empty merely because only the provider half was restored.

A workspace created elsewhere in the client appears on the selector's first
opening; users never need to close and reopen the menu to refresh it.

## Active work

The conversation timeline renders Markdown, code, reasoning summaries, tool
activity, permission requests, recovery notices, and final responses. Multiline
Markdown code blocks detect Arabic versus non-Arabic content for text direction:
Arabic code is RTL and other code is LTR. The code viewport itself always uses
an LTR horizontal scroll origin so long blocks open with their left edge visible. Skill
loading uses the same compact path-and-content presentation as File Read, while
the loaded `SKILL.md` body renders as selectable README-style Markdown rather
than raw tool JSON. File Read results for `.md` and `.markdown` targets place a
`Raw | MD` switch beside the target path, default to rendered Markdown, and
preserve the existing line-numbered source view under Raw. Both modes share one
fixed-height scrollable viewport so switching never moves the surrounding
timeline. The compact 8px-radius selector marks the active mode with the
application primary color at 20% opacity and reuses the tool-surface border at
5% on-surface opacity. Other file types keep the raw
presentation without a switch. Dynamic event titles resolve their own
text direction;
Arabic ask-user headers mirror
the complete header row while English headers remain left-to-right. Event
runtime metadata uses milliseconds below one second, seconds below one minute,
minutes plus seconds below one hour, and hours plus minutes thereafter.

While the agent is working:

- a normal send can steer the active run at the next safe boundary;
- `Ctrl+Enter` or `Cmd+Enter` explicitly adds work to the queue;
- queued work can be promoted to steering or removed;
- Stop cancels active generation and restores unexecuted input to the draft;
- reconnect and restart restore the authoritative session state.

The interface never treats a temporary disconnect as proof that a remote run
has stopped.

## Questions and permissions

When the agent calls the user-question tool, the composer area displays an
inline question card with the prompt, suggested answers, and a custom-answer
option. Submitting the answer resumes the same suspended turn.

Permission cards show the requested tool action and the available approval
scope. For file access outside the selected workspace, the card shows the
canonical target path without exposing write or edit content. Permission
decisions remain owned by the workspace and are distinct from ordinary
clarification answers.

## Providers and models

Provider settings are device-scoped. The user can create multiple provider
instances, including multiple accounts for the same provider, then select an
instance and model for a conversation.

Instances that support account-usage queries expose a **Usage & limits**
section. ChatGPT Subscription currently reports its Session and Weekly
allowances and reset times through this interface.

Runtime recovery cards let the user retry, choose another provider manually,
or accept an eligible automatic failover. Route changes remain visible and do
not silently substitute a different model.

## Workspaces and settings

Settings distinguish:

- account Client sessions and connected Agent devices, including current session, authoritative presence, Last active, and confirmed revoke;
- application preferences, such as appearance;
- device-level provider, MCP, skill, and runtime configuration;
- workspace-specific context, capabilities, and permissions.

Workspace configuration can override a user-level capability with the same
name. Inherited entries remain identifiable so the user can see their origin.

## Connection states

The client presents local-agent and hosted-relay state without blocking cached
navigation. Depending on the target and platform, available actions include
sign in, retry, start, repair, and restart.

Desktop can use a direct local connection or a hosted remote connection.
Mobile and web act as remote controllers for paired agents.

After a remote device record is created, the installation view keeps both
platform paths visible at once: macOS/Linux first and Windows PowerShell below
it. Each compact editor card has a platform label, one generated command,
horizontal overflow for long tokens, and an independent copy action. Running
that command installs the agent, prepares the creation-only pairing token, and
starts the service. The view continues automatically when the authoritative
inventory reports the new device Online.

## Accessibility and responsive behavior

Primary actions provide semantic labels and tooltips. Narrow layouts retain
touch-friendly targets, and the composer grows for multiline input without
hiding send, stop, permission, provider, model, or thinking controls.

Realtime voice exists as a separate experimental path and is not part of the
stable interface described here. See
[Experimental Realtime Voice](../technical/voice_streaming.md).
