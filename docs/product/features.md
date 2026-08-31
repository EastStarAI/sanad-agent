---
title: "Sanad Agent Features"
description: "A user-facing guide to Sanad Agent's local, remote, provider, workspace, tool, and interaction capabilities."
---

# Sanad Agent Features

Sanad Agent combines a native Dart agent with a Flutter client. The agent owns
execution and local state; the client gives you one interface for working with
the agent on your current computer or on paired remote devices.

## Local-first or connected across devices

On desktop, the client can connect directly to the agent on the same computer.
With a local provider such as Ollama, LM Studio, or llama.cpp, conversations,
workspace context, and supported tools can run without an internet connection.

When remote access is enabled, the same interface can manage paired computers
and headless servers through the optional Sanad hosted identity and relay
service. You can select a device, browse its independent workspaces and
conversations, and continue work from the desktop, mobile, or web client.
Workspace files and execution remain on the device running the agent.

## Parallel, durable sessions

Each conversation has independent execution and recovery state. Different
sessions can run concurrently without mixing their messages, tools, provider
route, or workspace context. Capacity is determined by the computer and the
connected model providers rather than by a fixed Sanad product limit.

Active work survives client reconnects, and durable session state lets the
client reconstruct running, queued, waiting, failed, and completed work after
an agent restart. Recovery safeguards avoid silently replaying tool side
effects whose outcome is ambiguous.

## Redirect active work without stopping it

Sanad supports live steering. Send a normal message while a run is active and
the agent can incorporate it at the next safe boundary, without cancelling the
run or discarding its progress.

Queueing is separate from steering:

- `Enter` or the Send button uses automatic delivery: steer an eligible active
  run, otherwise begin normal work.
- `Ctrl+Enter` on Windows/Linux or `Cmd+Enter` on macOS explicitly queues the
  request behind existing work.
- A queued request can be promoted to steering or removed.
- Stop returns work that was not executed to the conversation draft instead of
  losing it or sending it again automatically.

## Multiple providers and multiple accounts

You can configure different model providers and create multiple instances of
the same provider—for example, separate personal and work accounts. Every
instance owns its credentials, default model, readiness, rate limit, and
automatic-failover preference.

The provider and model can be changed inside a conversation. For eligible
failures, Sanad can move to another ready instance that is allowed to receive
failover while preserving the exact model identity. It does not silently
replace the selected model with a different one.

Provider templates include hosted APIs, ChatGPT Subscription, GitHub Copilot Subscription, local runtimes, and custom OpenAI- or Anthropic-compatible endpoints. GitHub Copilot sign-in uses GitHub's device-code flow in Sanad; it does not require the GitHub or Copilot command-line tools.

### Usage and limits

The provider settings can show authoritative account-usage windows for
ChatGPT Subscription, including the remaining Session and Weekly allowance and
their reset times. Usage support is discovered per provider instance. Other
providers will appear in this view when a compatible usage adapter is added;
Sanad does not fabricate usage data for unsupported providers.

## Workspaces, permissions, and context

Workspaces separate project context, sessions, drafts, provider selection, and
tool policy. Each workspace can use its own permission mode and persisted
approval decisions without changing another workspace.

Before a turn, the agent assembles supported project instructions such as
`AGENTS.md`, workspace skills, MCP servers, memory, and identity files. The
closest workspace configuration takes priority over user-level defaults when
the same capability is defined at both levels.

Sensitive tools remain subject to workspace policy, user approval, and
operating-system permissions. Computer-use tools such as screenshots,
keyboard, and mouse control are opt-in and require the corresponding system
access.

## Tools, MCP, and skills

The built-in tool catalog covers files, editing, directory and text search,
shell commands, web search and fetch, memory, user questions, and task
scheduling.

MCP servers can be configured at user or workspace scope. Sanad supports
stdio, Server-Sent Events, and streamable HTTP transports. Compatible
third-party marketing, video, data, or development tools can be connected
through MCP without being hard-coded into Sanad.

Sanad includes `skill-creator`, `find-skills`, and `agent-browser` with the
Agent installation. Their complete packages are embedded in the single Agent
executable and installed automatically into the active Sanad Home; no separate
skill download is required. A later Agent release can safely add, update, or
remove its managed copies while preserving skills the user changed or deleted.

Skills can also be installed globally for the user or locally for a workspace.
The agent discovers supported `SKILL.md` formats and loads the selected skill
when it is needed instead of injecting every skill into every prompt.

## The agent can ask you

When the agent needs a decision or missing information, it can pause the
current turn and display a question card in the conversation. The card can
offer suggested answers and a custom-response option. After you answer, the
same turn resumes with your response; it does not start an unrelated
conversation.

Permission requests use the same inline interaction model while remaining
separate from ordinary clarification questions.

## Memory and identity

File-backed long-term memory lets the agent preserve useful preferences and
working context between sessions. Memory is inspectable and can be updated as
work progresses.

`SOUL.md` customizes the agent's identity and general behavior. `USER.md` and
`MEMORY.md` provide persistent user and memory context, while workspace
instructions add project-specific guidance.

Memory updates are bounded and explicit. The agent can combine related removals,
replacements, and additions into one all-or-nothing update when space is tight.
Successful writes return a short confirmation rather than repeating the full
profile. Unsafe or incompatible file content is preserved for inspection instead
of being silently overwritten, and new memory becomes active only in a later
session snapshot.

## Scheduling

The agent can persist a task for a specific future time and execute it even
when the client window is closed, as long as the agent service remains
running. Recurring cron-style schedules are not part of the stable scheduling
surface yet.

## Experimental voice

Sanad includes an experimental realtime voice path using Gemini Realtime,
local WebSocket or hosted relay transport, PCM capture/playback, transcript
events, and barge-in. Voice is hidden by default and is not part of the stable
feature set. See [Experimental Realtime Voice](../technical/voice_streaming.md)
for its current boundaries.

## Designed for contributors and coding agents

Sanad keeps its development knowledge close to the code. Layered `AGENTS.md`
Runtime Contracts define durable ownership boundaries and local rules for the
repository, Dart agent, Flutter client, and focused subdirectories. A curated
[`docs/llms.txt`](../llms.txt) index makes the owning product, architecture,
operations, and QA pages discoverable to both people and coding agents.

The `sanad-dev` launcher can run a matched agent/client pair with isolated
worktree ports, Sanad Home, client preferences, runtime metadata, and logs.
Developers can inspect both processes, stream their logs, restart the Dart
agent under its supervisor, and hot reload or hot restart the Flutter client
without losing the worktree boundary.

Sanad can also develop the same source checkout used by its active daemon rather
than always launching a second copy. After a focused change passes analysis and
tests, a restart requested from the active tool turn waits for the restart tool
result to reach a durable checkpoint. The supervisor starts the updated source
and runtime recovery reclaims the same turn with the rebuilt tool catalog. The
turn can therefore repair a failed tool and retry its updated implementation, or
add temporary instrumentation, restart, read bounded post-restart logs, and fix
a stubborn runtime bug without starting another session or daemon. A live log
stream in a human-owned terminal can reconnect across the restart, while agent
tool calls use bounded log windows that terminate normally. Isolated worktrees
remain the safer boundary for parallel, broad, or bootstrap-sensitive changes.

The native Dart execution runtime and Flutter interface have explicit
responsibilities, while nearby contracts document the boundaries that changes
must preserve. See the [Developer Guide](../operations/developer_guide.md) for
the complete contributor workflow.

## Learn more

- [Installation and operation](../operations/user_guide.md)
- [Contributor workflow](../operations/developer_guide.md)
- [Provider configuration](../technical/provider_protocol.md)
- [Capability runtime](../agent_engine/capability_runtime.md)
- [Hosted services boundary](../technical/hosted_services_boundary.md)
- [Client interface](client_interface.md)
