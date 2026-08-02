<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="client/assets/brand/sanad-wordmark-horizontal-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="client/assets/brand/sanad-wordmark-horizontal.svg">
    <img src="client/assets/brand/sanad-wordmark-horizontal.svg" alt="Sanad Agent" width="720">
  </picture>
</p>

<p align="center">
  <strong>A local-first, cross-platform AI agent for your computers and servers—all managed from one interface.</strong>
</p>

<p align="center">
  <a href="https://sanad.eaststarai.com"><img src="https://img.shields.io/badge/Website-Sanad-2563EB?style=for-the-badge" alt="Sanad Agent website"></a>
  <a href="https://app.sanad.eaststarai.com"><img src="https://img.shields.io/badge/Web%20App-Open-0F766E?style=for-the-badge" alt="Open Sanad Client on the web"></a>
  <a href="docs/product/features.md"><img src="https://img.shields.io/badge/Features-Explore-2563EB?style=for-the-badge" alt="Explore Sanad Agent features"></a>
  <a href="docs/operations/user_guide.md"><img src="https://img.shields.io/badge/Docs-User%20Guide-0F766E?style=for-the-badge" alt="Sanad Agent documentation"></a>
  <a href="https://github.com/EastStarAI/sanad-agent/releases/latest"><img src="https://img.shields.io/github/v/release/EastStarAI/sanad-agent?display_name=tag&style=for-the-badge" alt="Latest Sanad Agent release"></a>
  <a href="https://github.com/EastStarAI/sanad-agent/actions/workflows/ci.yml"><img src="https://github.com/EastStarAI/sanad-agent/actions/workflows/ci.yml/badge.svg" alt="Sanad Agent build status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-16A34A?style=for-the-badge" alt="MIT License"></a>
  <a href="https://github.com/EastStarAI/sanad-agent/discussions"><img src="https://img.shields.io/badge/Community-Discussions-8250DF?style=for-the-badge" alt="Sanad Agent community discussions"></a>
  <a href="README.ar.md"><img src="https://img.shields.io/badge/Language-العربية-lightgrey?style=for-the-badge" alt="اقرأ بالعربية"></a>
</p>

Sanad Agent runs a native Dart agent close to your files and tools. Use it
locally with offline models, or install it on multiple computers and headless
servers and manage them from the same Flutter client on desktop, mobile, or
the web.

Sanad Agent is created by **Ahmed Attia** and developed under **EastStar AI**,
an independent AI studio.

<p align="center">
  <img src="docs/assets/screenshots/sanad-desktop-and-ios-simulator.png" alt="Sanad running on macOS alongside the iPhone Simulator" width="100%">
  <br>
  <em>One Sanad experience across desktop and mobile.</em>
</p>

## Why Sanad

| Capability | What it gives you |
|---|---|
| **One interface for every device** | Pair desktop computers and headless servers, then work with their independent workspaces and conversations from desktop, mobile, or web. |
| **Local-first, including offline use** | Connect the desktop client directly to the native Dart agent. With Ollama, LM Studio, or llama.cpp, supported conversations and tools can run without an internet connection. |
| **Redirect work in progress** | Steer an active run at the next safe boundary without stopping it, or queue separate work behind it. |
| **Parallel work that survives disruption** | Run isolated conversations concurrently and reconstruct running, queued, waiting, failed, and completed work after reconnect or agent restart. |
| **Bring your providers and accounts** | Configure different providers, multiple accounts for the same provider, local runtimes, and custom endpoints; switch routes inside a conversation and use eligible exact-model failover. |
| **Keep every workspace isolated** | Scope context, permissions, provider choice, conversations, drafts, MCP servers, and skills to the workspace that owns them. |
| **Memory and identity you can inspect** | Preserve long-term context in files and customize the agent with `SOUL.md`, `USER.md`, `MEMORY.md`, and workspace instructions. |
| **Built for contributors and coding agents** | Follow layered `AGENTS.md` Runtime Contracts and a curated documentation index; use isolated `sanad-dev` runtimes, live logs, supervised agent restart, and Flutter hot reload. |

Explore the complete capability set and its current boundaries in
[Sanad Agent Features](docs/product/features.md).

## Quick start

### For users

#### Use Sanad on your desktop

1. Download Sanad Client for a publicly distributed platform from the
   [latest release](https://github.com/EastStarAI/sanad-agent/releases/latest).
   The first iOS release is available only through Internal TestFlight, not as
   a public GitHub Release download.
2. Launch the client and choose the local-device path.
3. Configure a local provider such as Ollama, LM Studio, or llama.cpp—or add a
   hosted provider.
4. Select a workspace and start a conversation.

A Sanad account is not required for the local-only path.

#### Add a remote computer or server

1. Open Sanad Client on desktop, mobile, or the web.
2. Create and name a device.
3. Copy the generated command and run it once on the target computer or
   headless server. It installs, pairs, and starts Sanad Agent.
4. Select the device from the same Sanad Client and begin working with its
   workspaces and conversations.

For macOS or Linux:

```bash
curl -fsSL https://sanad.eaststarai.com/install.sh | bash -s -- --pairing-token '<pairing-token>'
```

For Windows PowerShell:

```powershell
& ([scriptblock]::Create((irm https://sanad.eaststarai.com/install.ps1))) -PairingToken '<pairing-token>'
```

> **Unsigned Windows build:** The `1.0.0` Windows installer is intentionally
> unsigned. Verify that it came from the official release and that its SHA-256
> matches the published release manifest before proceeding. Do not disable
> Microsoft Defender or Smart App Control. The `1.0.0` clean-machine release
> gate was validated on Windows 11; Windows 10 was not validated for this
> release.

Sanad Client inserts a creation-only pairing token into the copied command.
The installer verifies the selected release artifact, prepares pairing, and
starts the background service. On the first successful connection, the agent
replaces that visible token with a durable credential generated locally; the
initial token cannot be reused.

See [Install and Use Sanad Agent](docs/operations/user_guide.md) for client
packages, manual agent installation, service management, providers, updates,
and removal.

### For developers

Clone the repository and enter its directory:

```bash
git clone https://github.com/EastStarAI/sanad-agent.git sanad-agent
cd sanad-agent
```

On macOS or Linux, bootstrap and run the complete managed pair with:

```bash
scripts/sanad-dev
```

On Windows PowerShell, run:

```powershell
.\scripts\sanad-dev.ps1
```

The bootstrap installs the verified user-scoped FVM release when needed,
installs the repository-pinned Flutter SDK, resolves Agent and Client
dependencies, and installs the cross-platform `sanad-dev` user command. No
administrator access is required.

For Flutter device selection, local-only operation, development commands, and
testing workflows, follow the
[Developer Guide](docs/operations/developer_guide.md).

## Choose how you work

| Mode | Where the agent runs | Where you control it | Sanad account |
|---|---|---|---|
| Local desktop | The same macOS, Linux, or Windows computer | Desktop client through a direct local connection | Not required |
| Connected computer | A paired desktop or remote computer | Desktop, mobile, or web client | Required |
| Headless server | A paired macOS, Linux, or Windows server | Desktop, mobile, or web client | Required |
| Standalone CLI | The current computer or server | Terminal | Not required locally; required for connected-device access |

## How it works

```text
Flutter Client
├── Direct local connection ─────────► Dart Agent on this computer
└── Optional hosted connection ──────► Sanad Gateway ─────► Dart Agent on a remote device

Dart Agent
├── Workspaces, sessions, recovery, memory, and provider configuration
├── Built-in tools, MCP servers, skills, and permission enforcement
└── Local model or external model-provider connection
```

The Dart agent owns execution and local state. The Flutter client provides the
interface for selecting devices, workspaces, conversations, providers, and
models while rendering messages, tools, permissions, questions, queues, and
recovery state.

## Repository structure

- [`agent/`](agent/) — native Dart CLI and background service that owns
  execution and local state.
- [`client/`](client/) — Flutter interface for local and remote devices.
- [`docs/`](docs/) — product, technical, operations, and QA documentation.
- [`scripts/`](scripts/) — development, documentation, build, and release
  tooling.

## Key interactions

### Steer while the agent works

Send a normal message during an active run to redirect it at the next safe
boundary without discarding its progress. Use `Ctrl+Enter` on Windows/Linux or
`Cmd+Enter` on macOS to queue a separate request instead. Queued work can be
promoted to steering or removed, and Stop restores unexecuted input to the
draft.

### Let the agent ask

The agent can suspend a turn and show a question card with suggested answers
and a custom-response option. Your answer resumes the same turn. Permission
requests use a separate inline card and remain governed by workspace policy.

### Use multiple providers and accounts

Create multiple instances of one provider—for example, separate personal and
work accounts. Each instance has independent credentials, model, readiness,
rate limits, and failover policy. ChatGPT Subscription instances can also show
their authoritative Session and Weekly usage windows.

### Extend it with MCP and skills

Connect MCP servers over stdio, Server-Sent Events, or streamable HTTP, and
install skills globally for the user or locally for a workspace. Workspace
definitions take priority over user-level capabilities with the same name.

## Platforms

| Component | Platforms |
|---|---|
| Sanad Agent | macOS, Linux, and Windows, including headless operation |
| Sanad Client | macOS, Windows, Linux, Android, iOS (Internal TestFlight for the first release), and Web |

## Feature status and constraints

- **Scheduling:** persisted one-shot tasks can run while the agent service
  remains active. Recurring cron-style schedules are not part of the stable
  scheduling surface.
- **Computer use:** desktop screenshot, keyboard, and mouse tools require
  explicit enablement and the corresponding operating-system permissions.
- **Realtime voice:** the Gemini Realtime voice path is experimental, hidden
  by default, and not part of the stable feature set. See
  [Experimental Realtime Voice](docs/technical/voice_streaming.md).
- **Capacity:** Sanad does not impose a fixed product count on conversations
  or provider instances; practical capacity depends on the device and the
  connected providers.

## Documentation

| Guide | What it covers |
|---|---|
| [Features](docs/product/features.md) | Complete user-facing capabilities, constraints, and experimental boundaries |
| [Installation and User Guide](docs/operations/user_guide.md) | Client and agent installation, device pairing, providers, updates, service management, and removal |
| [Developer Guide](docs/operations/developer_guide.md) | Source setup, tests, isolated worktrees, logs, restart controls, and Flutter reload |
| [Client Interface](docs/product/client_interface.md) | Devices, workspaces, conversations, steering, queues, questions, permissions, providers, and responsive behavior |
| [Provider Protocol](docs/technical/provider_protocol.md) | Provider templates, instances, credentials, models, readiness, usage, and failover |
| [Hosted Connectivity](docs/technical/hosted_services_boundary.md) | Identity, device inventory, remote relay, and the state that remains owned by the selected agent |
| [Technical Documentation](docs/technical/MOC.md) | Agent/client runtime, protocols, persistence, platform integration, and hosted connectivity |
| [Agent Engine](docs/agent_engine/MOC.md) | Model execution, tools, MCP, skills, prompts, and capability contracts |
| [QA and Recovery](docs/qa_maintenance/MOC.md) | Regression matrices and recovery behavior |
| [Machine-readable Index](docs/llms.txt) | Curated documentation entry points for developers and coding agents |

## Security and privacy

Local workspaces, conversations, provider configuration, memories, and
execution state are owned by the agent running on the selected device.
Connected-device features exchange the identity, device inventory, commands,
and events necessary to operate the remote relay.

Never commit API keys or tokens. Provider credentials and Sanad identity
tokens are runtime user data outside Git, and diagnostic serialization redacts
credential-shaped fields.

Report vulnerabilities privately according to [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md),
follow the nearest `AGENTS.md` Runtime Contract, and read
[CODE_OF_CONDUCT.md](.github/CODE_OF_CONDUCT.md). Contributions require no CLA or DCO;
required checks and protected review labels apply, and human pull requests use
squash merge.

## Community

- **Issues:** [Report a bug or request actionable work](https://github.com/EastStarAI/sanad-agent/issues)
- **Discussions:** [Propose an idea or ask an architectural question](https://github.com/EastStarAI/sanad-agent/discussions)
- **Community:** [Join the Sanad Agent Discord](https://discord.gg/RPTJ2X9rn)
  (permanent project invite, lands in `#help-and-support`).
- **Support:** [Choose the correct help channel](.github/SUPPORT.md)
- **Governance:** [Read how decisions and contributions work](.github/GOVERNANCE.md)
- **Security:** [Report vulnerabilities privately](SECURITY.md)
- **Code signing:** [Review artifact trust and signing policy](docs/operations/code_signing_policy.md)

## License

Sanad Agent is available under the [MIT License](LICENSE).

Copyright © 2026 Ahmed Attia, operating as EastStar AI.
