---
title: "Sanad Agent Product Definition"
description: "Current product scope, users, components, operating modes, capabilities, and boundaries."
---

# Sanad Agent Product Definition

## Product summary

Sanad Agent is an independent open-source agent system for running AI-assisted
work close to the user's files and devices. It combines:

- a native Dart agent for execution, tools, providers, memory, and local state;
- a Flutter client for local and remote interaction on desktop, mobile, and
  web.

The product supports a local-first path and an optional connected-device path.
Hosted services add identity, device pairing, and remote relay; they do not
replace the agent or own workspace execution.

## Primary users

- A desktop user who wants an agent working directly with local files and
  local or hosted models.
- A developer or operator who runs the agent on a headless server.
- A user who manages several computers and servers from one client.
- A mobile or web user who connects to agents running on paired devices.
- A contributor extending providers, MCP, skills, tools, or the client.

## Components

### Sanad Agent

The agent runs on macOS, Linux, and Windows as a CLI or background service. It
owns:

- workspaces, conversations, messages, drafts, and execution state;
- model-provider instances, credentials, route selection, and recovery;
- tools, MCP servers, skills, permissions, and workspace context;
- memory, scheduling, and durable recovery;
- local and hosted-connection interfaces.

The `sanad` command supports interactive use, daemon operation, authentication,
provider setup, service management, and updates.

### Sanad Client

The Flutter client runs on macOS, Windows, Linux, Android, iOS, and web. It
provides:

- device selection and management;
- workspace and conversation navigation;
- message composition, steering, queueing, stopping, and recovery;
- provider/model configuration and supported usage views;
- inline tools, permission requests, and user-question cards;
- responsive desktop, mobile, and web layouts.

## Operating modes

### Local-only

The desktop client connects directly to the agent on the same computer. With a
local model provider, supported model and tool operations can run without an
internet connection or Sanad hosted services.

### Connected devices

The user signs in, pairs one or more computers or servers, and selects them
from the same client. The optional hosted service relays commands and events.
Each agent keeps its own workspaces, provider configuration, conversations,
memory, and runtime state.

## Device onboarding and lifecycle

### Local desktop

On desktop, the client checks the local agent health endpoint before opening a
workspace. If a compatible agent is available, the user can continue directly.
If it is absent, the client guides the user through installing or starting the
native agent rather than asking for a source development environment.

The local-only path does not require a Sanad account. Signing in is an explicit
transition to connected-device capabilities, not a prerequisite for local
work.

### Remote computer or server

From the client, the user creates a device entry and receives a one-time
installation command containing an initial pairing token. Running that command on a
supported remote machine installs the standalone agent, registers its
background service, and associates the device with the user's account.

For `1.0.0`, the Gateway consumes that initial token on the first successful
connection and replaces it with a durable credential generated locally by the
agent. A post-v1 pairing lifecycle will add an explicit expiration window and
regeneration UX.

The new device must appear in the same device selector used by desktop, mobile,
and web clients. Pairing does not copy workspaces or provider credentials
between devices; it grants authenticated routing to the selected agent.

### Device management

Device creation is reached through **Settings → + beside Devices in the
Settings sidebar → Add device**.

The client must show enough state to distinguish:

- local and remote devices;
- online, offline, connecting, and recovery states;
- the currently selected device;
- installed-agent version and update state when available.

Renaming or removing a device affects the connected-device relationship. It
must not silently delete local workspace files or the agent's Sanad Home.

## Client information architecture

The primary hierarchy is:

```text
Device
  └── Workspace
        └── Conversation
              └── Messages, tool activity, questions, and pending input
```

Desktop layouts can present device, workspace, and conversation navigation
side by side. Narrow mobile and web layouts preserve the same hierarchy through
drawers or routed views without changing ownership or moving execution into the
client.

The active conversation surface includes:

- message and attachment composition;
- provider and model selection;
- active-run state and stop control;
- pending-input visibility and draft recovery;
- inline tool status, permission decisions, and clarification cards.

## Core behavior

### Sessions and active work

Sessions are isolated and can execute concurrently. Each session has a
daemon-owned execution state and FIFO pending-input queue.

During active work, a normal message can steer the run at a safe boundary
without stopping it. Explicit queue intent places work behind existing items.
Stop cancels the active run and returns unexecuted input to the client draft.

Durable state supports reconnect and restart recovery while preventing unsafe
automatic replay of ambiguous tool side effects.

#### Input intent while work is active

The composer exposes three distinct outcomes:

- **Steer:** deliver new guidance at the next safe runtime boundary and
  continue the current task.
- **Queue:** append a separate request to the session's pending FIFO input.
- **Stop:** cancel the active run and preserve unexecuted user input as a
  recoverable draft.

The UI must not present these actions as synonyms. Reconnect and refresh must
reconstruct pending items from daemon-owned state instead of relying on a
client-only queue.

#### Concurrent conversations

Different sessions may run concurrently without sharing active-turn state,
pending input, provider route mutation, or permission prompts. Product
documentation should describe concurrency without promising an artificial
"unlimited" count; practical capacity depends on the device and providers.

### Workspaces and safety

A workspace scopes project context, sessions, drafts, provider choice,
permissions, skills, and MCP configuration. User-level defaults can be
overridden by a closer workspace definition.

Sensitive tools require the permission allowed by workspace policy and the
operating system. Computer-use capabilities are opt-in.

### Providers

The user can configure different providers and multiple instances of the same
provider. Each instance owns independent credentials, model defaults,
readiness, rate limits, and failover policy.

The active provider and model can change within a conversation. Automatic
failover is limited to eligible, allowed, ready instances while preserving the
exact model identity.

ChatGPT Subscription supports authoritative Session and Weekly usage windows.
Other providers expose usage only when a compatible adapter exists.

### Extensibility

Built-in tools cover files, shell execution, search, web access, memory,
scheduling, and user questions.

MCP servers and skills can be defined at user or workspace scope. Workspace
definitions take priority when names overlap. MCP supports stdio, SSE, and
streamable HTTP transports.

### Context and memory

The agent assembles supported workspace instructions, skills, MCP tools,
memory, and identity context for each turn. `SOUL.md` customizes identity;
file-backed memory preserves inspectable context between sessions.

### Clarification

The agent can suspend a turn and ask the user a question. The client displays
an inline card with suggested answers and a custom-response option, then
resumes the same turn with the selected response.

### Scheduling

The stable scheduling surface supports persisted work at a specific future
time. Recurring cron-style automation is outside the current stable scope.

## Connection and recovery requirements

The client chooses a transport from the selected device:

- a direct local connection for the agent running on the same desktop;
- the authenticated hosted relay for a paired remote device.

Connection loss must be visible and recoverable. The client can reconnect and
request authoritative conversation, execution, and queue state. It must not
infer that an in-flight run stopped merely because the UI disconnected.

Agent restart recovery follows durable checkpoints. Safe, idempotent work may
continue according to runtime policy; ambiguous tool effects become an
explicit blocked/recovery state requiring user action.

## Privacy and security requirements

- Workspace tools execute on the selected agent device.
- Provider credentials and device identity remain in the selected Sanad Home.
- Local-only use must not require hosted authentication.
- Hosted services receive the data required for authentication and relay when
  connected-device mode is used.
- Permission requests remain scoped to the active workspace and operation.
- Tokens, provider keys, runtime dumps, and user state must not enter source
  control, public logs, or release packages.

## Product quality requirements

- The agent and client must remain independently restartable.
- One failed session must not terminate unrelated active sessions.
- Desktop, mobile, and web clients must preserve the same device/workspace/
  conversation ownership model.
- Platform-specific installers must not require end users to install developer
  SDKs.
- Public feature claims must be backed by current code, tests, or a verified
  release artifact and must label experimental scope.

## Distribution

GitHub Releases is the source for native agent binaries and client packages.
Official installer scripts download verified release assets and can pair a
headless device using a token created in Sanad Client.

Android is distributed through Google Play under the package identity
`com.eaststarai.sanad`, and iOS is limited to Internal TestFlight for the first
release. Store-distributed mobile builds are clients only: they never host the
native agent service.

Installed agents expose unified service and update commands. Platform packages,
checksums/signatures, install scripts, and update feeds must pass the launch
release gates before the first public push.

## Experimental scope

Realtime voice is an experimental Gemini Realtime path hidden by default. It
is documented separately and is not part of the stable product promise.

## Out of scope

- Hosted service source code and production infrastructure.
- Silent substitution of a different model during provider failover.
- Recurring schedules presented as stable before their runtime is complete.
- Third-party MCP services presented as bundled or official partnerships.
- A separate hosted voice-agent architecture outside the experimental Gemini Realtime path.
