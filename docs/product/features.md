---
title: "Sanad Agent Features"
description: "A user-facing guide to Sanad Agent's local, remote, provider, workspace, tool, and interaction capabilities."
---

# Sanad Agent Features

Sanad Agent combines a native Dart agent with a Flutter client. The agent owns
execution and local state; the client gives you one interface for working with
the agent on your current computer or on paired remote devices.

This page is an overview. Every section links to the page that owns its details.

## Local-first or connected across devices

On desktop the client can connect directly to the agent on the same computer,
and with a local provider the conversation, its workspace context, and the
supported tools run without an internet connection. Enabling remote access adds
paired computers and headless servers reached through the optional hosted
identity and relay service, so the same interface follows you to another
computer, the web app, or mobile. Workspace files and execution stay on the
device running the agent, and a remote device only exposes the workspace folder
it manages.

See [Hosted Services Boundary](../technical/hosted_services_boundary.md),
[Workspace Folder Mutation Protocol](../technical/workspace_folder_mutation_protocol.md),
and the [User Guide](../operations/user_guide.md) for the channel each platform
installs from.

## Accounts, devices, and the hosted service

The hosted service is optional and owns the account, not the work: it signs you
in, lists your client sessions and registered Agents, and can revoke either of
them. You can delete the whole account from your profile after an explicit
confirmation, which removes the hosted identity and its credentials and leaves
the Agent files and conversations on your own devices. Remote commands, remote
dictation, and attached media travel through the same relay, so those features
need a signed-in connection that both ends can authenticate.

See [Hosted Services Boundary](../technical/hosted_services_boundary.md) and
[Settings Hub](settings_hub.md).

## Parallel, durable sessions

Each conversation keeps its own execution and recovery state, so sessions run
side by side without mixing messages, tools, provider route, or workspace.
Active work survives a client reconnect, and after an agent restart the client
reconstructs what was running, queued, waiting, failed, or completed instead of
replaying a tool whose outcome is unknown. You can search the selected device's
conversation titles and messages, and a long conversation keeps working through
compaction, which summarises older turns while preserving the goal.

See [Client Interface](client_interface.md), [Conversation Navigation](conversation_navigation_ux_spec.md),
and [Context Compaction](../technical/context_compaction.md).

## Redirect active work without stopping it

Send a message while a run is active and the agent can take it at the next safe
boundary; explicit queueing puts a request behind the current work, a queued
request can be promoted to steering or removed, and Stop returns unexecuted text
to your draft. The latest turn can also be edited or retried in place, and any
final answer can be forked into an independent conversation that keeps the
history behind it.

See [Client Interface](client_interface.md), [Message Edit and Retry](message_edit_retry_ux.md),
and [Conversation Fork](conversation_fork_ux.md).

## Files and images in the composer

Paste, drop, or pick files and images and they enter the draft through one path;
the agent can read them, and it can open an image directly when it needs to see
one. Media sent back by the agent opens in a viewer and can be downloaded.

See [Client Interface](client_interface.md) and
[Multimodal Tool Results and View Image](../technical/multimodal_tool_results_and_view_image.md).

## Multiple providers and multiple accounts

Configure several providers, or several instances of one provider such as
separate personal and work accounts, each with its own credentials, default
model, readiness, and failover preference; the provider and model can be changed
inside a conversation. Failover moves to another ready instance while preserving
the selected model identity, and thinking level is chosen per model. Provider
setup explains a rejected credential instead of echoing a provider response, and
account-usage windows appear only where the provider publishes them.

See [Provider Protocol](../technical/provider_protocol.md) and
[Provider Account Usage Limits](provider_account_usage_limits.md).

## Workspaces, permissions, and context

Workspaces separate project context, sessions, drafts, provider selection, and
tool policy, and each one keeps its own permission mode and remembered
approvals. Before a turn the agent assembles the project instructions, workspace
skills, MCP servers, memory, and identity it supports, and the closest
configuration wins over a broader default when the same capability is defined at
both. Sensitive tools remain behind workspace policy, your approval, and
operating-system permissions, and computer-use tools are opt-in.

See [Workspace Identity](../technical/workspace_identity_protocol.md), [Execution Trust and Permission Authority](../technical/execution_trust_and_permission_authority.md),
and [Capability Runtime](../agent_engine/capability_runtime.md).

## Tools, MCP, and skills

Sanad ships a built-in tool catalog that covers the workspace, the shell, the
web, images, memory, questions, scheduling, and user secrets; the owning page
lists each family and the guarantees behind it. MCP servers can be configured
for the user or for one workspace, and compatible third-party marketing, video,
data, or development tools connect through MCP instead of being hard-coded into
Sanad.

Product skills ship inside the Agent executable and are reconciled into your
Sanad Home on each start without overwriting skills you changed or deleted.
Skills can be installed for the user or for one workspace, and a third-party
skill installs from a public source with recorded provenance and content
screening.

See [Capability Runtime](../agent_engine/capability_runtime.md) and
[MCP Server Configuration](../technical/mcp_server_configuration.md).

## The agent can ask you

When the agent needs a decision or a missing detail it pauses the turn and shows
a question card, with suggested answers and room for your own, and the same turn
resumes with your reply. Permission requests use the same inline pattern and stay
separate from ordinary questions. Credentials are requested the same way: a
secret you store for a device is collected outside the conversation and is never
read back from the transcript.

See [Capability Runtime](../agent_engine/capability_runtime.md), [Settings Hub](settings_hub.md),
and [Secret Management Protocol](../technical/secret_management_protocol.md).

## Memory and identity

Long-term memory is file-backed and inspectable: an identity, a user profile, and
a memory that the agent maintains across sessions, alongside the instructions
each workspace contributes. Memory writes are bounded and applied atomically,
become prompt-visible only in a later session, and never overwrite content the
agent cannot safely rewrite; such content is preserved for you to inspect.

See [Agent Runtime](../technical/agent_runtime.md).

## Scheduling

Schedules let a device run one-shot or recurring work without you starting a
conversation, and they survive a daemon restart. A Schedules page in the sidebar
creates, edits, pauses, resumes, runs, and reviews the history of device-owned
schedules, while the agent manages through its scheduling tool only the
schedules its own conversation created. A conversation that owns schedules says
so, and deleting it pauses them instead of losing them.

See [Schedule Control Protocol](../technical/schedule_control_protocol.md).

## Local dictation

Press the microphone in the composer and speak: the words land where the caret
was, and anything you typed stays yours. Recognition runs inside the Agent and
never in the app, which only captures audio and inserts the text that comes back.

When the client and the agent are on the same computer the audio never leaves it.
When the device is reached over the cloud, or the client is the web or mobile
app, the audio travels through the Sanad relay to the Agent that transcribes it,
so that channel is hosted rather than local.

Dictation runs on the desktop platforms where the Agent runs, and some platforms
or older CPUs cannot run local recognition; a device that cannot dictate reports
why, and the model sheet offers the local speech models to download for Arabic or
English. Nothing stays loaded between sessions, and dictation is a stable,
text-only feature — separate from the experimental realtime voice call below.

See [Local Dictation](../technical/local_dictation.md),
[Dictation Transport Protocol](../technical/dictation_transport_protocol.md), and
[Native Dictation Runtime Platforms](../technical/native_stt_runtime_platforms.md).

## English and Arabic, and your look

The interface is fully English and Arabic with a right-to-left layout, and dates
follow your locale. Theme, primary color, font family, and text size are set per
device and follow you across a local and a cloud connection.

See [Client Multilanguage](../technical/client_multilanguage.md), [Design System](../technical/design_system.md),
and [Settings Hub](settings_hub.md).

## Staying up to date

The Client checks for and applies its own signed update, and the Agent updates
through its command line, naming the trust stage that failed when verification
does not pass.

See [Release and Update Architecture](../technical/update_architecture.md) and the
[User Guide](../operations/user_guide.md).

## Command line and background operation

`sanad` works against the Agent on the machine you are on, and `sanad-client`
relays a command to another paired device through a running Client. Closing the
desktop window does not stop the Client: its connections, agent link, and command
endpoint stay up, with a tray control to reopen or quit.

See [Sanad CLI Architecture](../technical/sanad_cli_architecture.md),
[Remote CLI Relay Protocol](../technical/remote_cli_relay_protocol.md),
[Client CLI and Background Operation](client_cli_and_background_operation.md), and
[Desktop Background and System Tray](../technical/desktop_background_and_system_tray.md).

## Experimental realtime voice

Sanad also contains an experimental realtime voice call — Gemini Realtime over a
local or hosted transport, with PCM capture and playback, transcript events, and
barge-in — hidden by default and outside the stable feature set. It is a separate
path from the dictation described above.

See [Experimental Realtime Voice](../technical/voice_streaming.md) for its current
boundaries.

## Designed for contributors and coding agents

Sanad keeps its development knowledge close to the code. Layered `AGENTS.md`
Runtime Contracts define durable ownership boundaries and local rules for the
repository, Dart agent, Flutter client, and focused subdirectories, and a curated
[`docs/llms.txt`](../llms.txt) index makes the owning product, architecture,
operations, and QA pages discoverable to both people and coding agents.

The `sanad-dev` launcher runs a matched agent/client pair with isolated worktree
ports, Sanad Home, client preferences, runtime metadata, and logs, and lets you
inspect both processes, stream their logs, restart the agent under its supervisor,
and hot reload or hot restart the client without losing the worktree boundary.

Sanad can also develop the same source checkout its active daemon runs: a restart
requested from the active tool turn waits for the restart result, and recovery
reclaims that turn with the rebuilt tool catalog, so a turn can fix a failed tool
or add temporary instrumentation without starting another session. Isolated
worktrees remain the safer boundary for parallel, broad, or bootstrap-sensitive
changes.

See the [Developer Guide](../operations/developer_guide.md) for the complete
contributor workflow.

## Learn more

- [Installation and operation](../operations/user_guide.md)
- [Client interface](client_interface.md)
- [Settings hub](settings_hub.md)
- [Local dictation](../technical/local_dictation.md)
- [Schedule control protocol](../technical/schedule_control_protocol.md)
- [Contributor workflow](../operations/developer_guide.md)
- [Provider configuration](../technical/provider_protocol.md)
- [Capability runtime](../agent_engine/capability_runtime.md)
- [Hosted services boundary](../technical/hosted_services_boundary.md)
