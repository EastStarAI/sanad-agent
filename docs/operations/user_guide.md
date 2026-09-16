---
title: "Install and Use Sanad Agent"
description: "Install the Sanad client and agent, connect local or remote devices, configure providers, manage the service, and update Sanad."
---

# Install and Use Sanad Agent

Sanad has two components:

- **Sanad Client** is the Flutter interface for desktop, mobile, and web.
- **Sanad Agent** is the native background service that runs on macOS, Linux,
  or Windows and owns workspace execution and local state.

For a normal desktop setup, install the Client and choose **Run Locally**; the
Client installs and starts the matching Agent on the same computer. For a
server or another computer, keep the Client on your preferred device and
install only the standalone Agent on the remote machine.

## Install Sanad Client

Use the Production convenience link for your platform. Each link redirects to
the matching public Stable Client artifact, so end users do not need to choose
from the mixed Client, Agent, checksum, and update files on GitHub Releases.

| Platform | Install or open |
|---|---|
| macOS | [Download Sanad Client for macOS](https://downloads.sanad.eaststarai.com/client/macos) |
| Windows | [Download Sanad Client for Windows](https://downloads.sanad.eaststarai.com/client/windows) |
| Linux | [Download Sanad Client for Linux](https://downloads.sanad.eaststarai.com/client/linux) |
| Android | No stable public app yet; use the Web Client |
| iOS | No stable public app yet; use the Web Client |
| Web | [app.sanad.eaststarai.com](https://app.sanad.eaststarai.com) |

These aliases exist only on the unprefixed Production downloads host. Their
Stable destinations are verified against the release manifest before an edge
configuration update; Development and Staging do not publish equivalent links.

### macOS

1. Open the versioned macOS DMG.
2. Drag Sanad Client to Applications.
3. Launch Sanad Client and approve the operating-system prompts required by the
   features you choose to use.

### Windows

The `1.0.1` package is an **Unsigned Windows build**. Download it only from the
official release, compare its SHA-256 with the published release manifest, and
then run the versioned Windows x64 installer. Do not disable Microsoft Defender
or Smart App Control. If SmartScreen warns after origin and hash verification,
use the operating-system review flow to inspect the publisher status before
choosing whether to continue. Windows release gates run on Windows 11. Windows
10 has not been validated and no Windows 10 result should be inferred from the
shared x64 package.

After installation, launch Sanad Client from the Start menu.

### Linux

Download the versioned Linux x64 `.deb`, open it with the Ubuntu/Debian software
installer, and select **Install**. The package adds Sanad to the applications
menu with its desktop icon. For terminal installation, run
`sudo apt install ./sanad-client-<version>-linux-x64.deb` from the download
directory. The portable `tar.gz` remains available for advanced users who do
not want a system installation.

## Use Sanad locally

On desktop, choose **Run Locally** during setup. The Client downloads the
release manifest and matching Agent artifact, verifies the artifact, registers
the background service, starts it, and connects directly on the same computer.
You do not need to run a separate Agent installer.

Add a model provider before sending model-backed requests. To keep the
supported execution path local, configure Ollama, LM Studio, or llama.cpp in
Provider Settings. You can also configure hosted APIs or ChatGPT Subscription.

Local workspaces, conversations, provider configuration, memories, and
execution state are stored by the agent on that computer.

## Add a remote computer or server

You can install the native agent on a headless server without installing the
Flutter client there.

1. Sign in to Sanad Client on desktop, mobile, or web.
2. Open **Device Management** and choose **Add device**.
3. Give the device a name.
4. Copy the complete generated command and run it once on the target computer
   or server. Do not extract, reconstruct, or share its embedded credential.

The installer detects the operating system and architecture, reads the public
release manifest, verifies the selected artifact, installs the `sanad` command,
prepares the initial pairing state, and starts the background service. The
pairing credential in the generated command is short-lived and is not the
durable device credential: the Agent generates that credential locally and the
Gateway invalidates the initial credential on the first successful connection.

## Install the Agent without an Add device command

This is an alternative to the Client-generated **Add device** command. The
installer offers Portal sign-in on an interactive terminal. You may decline and
continue in local-only mode.

For macOS or Linux:

```bash
curl -fsSL https://sanad.eaststarai.com/install.sh | bash
```

For Windows PowerShell:

```powershell
irm https://sanad.eaststarai.com/install.ps1 | iex
```

Press Enter at the prompt to sign in through the Portal, or answer `n` to run
locally and connect later. For automation, select the behavior explicitly:

| Behavior | macOS/Linux option | Windows PowerShell option |
|---|---|---|
| Start Portal sign-in | `--login` | `-Login` |
| Do not sign in | `--no-login` | `-NoLogin` |

A tokenless, non-interactive installation defaults to local-only mode and never
waits for input. After successful authentication, a clean installation starts
the newly registered service. A reinstall or upgrade refreshes a previously
running service so it loads the replacement executable and stored
authentication; a previously stopped service is started with the new state.
When an existing installation is authenticated, reinstall and upgrade require
cloud registration health before reporting that the account connection was
restored; they do not describe that installation as local-only.
If you sign in later after choosing local-only mode, follow `sanad login` with
`sanad service restart` so the running daemon loads the stored authentication.

## Install the standalone agent manually

Manual installation is useful when reviewing each step or when an environment
does not allow a piped installer.

1. Download the agent from the
   [latest release](https://github.com/EastStarAI/sanad-agent/releases/latest):

   - macOS arm64: `sanad-agent-<version>-macos-arm64`
   - macOS x64: `sanad-agent-<version>-macos-x64`
   - Linux x64: `sanad-agent-<version>-linux-x64`
   - Windows x64: `sanad-agent-<version>-windows-x64.exe`

2. Verify the checksum or signature published with the release.
3. Rename the executable to `sanad` (`sanad.exe` on Windows) and place it in a
   directory on `PATH`.
4. Connect the Agent through Portal sign-in when needed:

   ```bash
   sanad login --portal
   ```

   To use creation-time pairing instead, run the complete command generated by
   **Add device** rather than manually extracting its credential.

5. Install and start the background service:

   ```bash
   sanad service install
   ```

If the service was already running when you signed in, reload the stored
authentication with `sanad service restart`.

## Manage the agent service

The same service commands are available on macOS, Linux, and Windows:

```bash
sanad service status
sanad service start
sanad service stop
sanad service restart
sanad service uninstall
```

Closing Sanad Client does not stop an installed agent service. Active or
scheduled work can continue on the device while the service is running.

On Linux, the same command automatically selects a durable user systemd service
only when its bus and linger capability are healthy. Otherwise it registers a
system systemd unit that still runs the Agent as an unprivileged account, or a
native OpenRC service when OpenRC is the host init manager. `service status`
reports `Missing`, `InstalledStopped`, `Running`, `Failed`, or
`ManagerUnavailable`, together with the selected scope and credential backend.
An unsupported init manager fails explicitly rather than leaving a detached
process that disappears after logout or reboot. The Add Device surface follows
the conventional `curl -fsSL ... | bash` bootstrap on POSIX and shell-quotes its
creation token. The installer passes that token to the Agent through stdin,
never through Agent process arguments, and reports success only after the
installed version responds locally and, for connected installs, cloud
registration is complete. A failed attempt restores the prior executable,
service state, and pending pairing state without deleting the wider Sanad Home.

## Providers and accounts

Open Provider Settings on the selected device to:

- add a provider;
- add another account for the same provider;
- select the default model for each account;
- enable or disable automatic failover per provider instance;
- configure local or custom OpenAI-/Anthropic-compatible endpoints;
- view **Usage & limits** for supported instances.

ChatGPT Subscription currently exposes Session and Weekly usage windows.
Unsupported providers do not display invented usage values.

## Work with an active session

- Send normally while the agent is working to steer it at the next safe
  boundary without stopping the run.
- Use `Ctrl+Enter` or `Cmd+Enter` to queue work explicitly.
- Promote or remove a queued request from its queue card.
- Use Stop to cancel the active run; unexecuted input returns to the draft.
- Answer an agent question from its inline card by choosing a suggested answer
  or entering a custom response.

## Command Line Interface (CLI) Guide

Sanad includes a rich command-line tool (`sanad`) that gives you full access to
all agent capabilities directly from the terminal without requiring the desktop client.

### Connection and Runtime Modes

1. **Attached Gateway Mode (Default):**
   When the background daemon is running, `sanad` automatically connects to it
   over a local authenticated WebSocket (`ws://127.0.0.1:58085/gateway`). Workspaces,
   conversations, active runs, and provider configurations are shared seamlessly
   with the desktop and web clients.

2. **Standalone Fallback Mode:**
   When running on a headless server without a daemon, in CI/CD containers, or
   when `--standalone` is passed, the CLI falls back to executing in-process
   using local provider credentials and state.

### Interactive Chat (REPL)

To launch an interactive reasoning session, simply run:

```bash
sanad
```

Or pass flags to customize the session:

```bash
sanad chat --workspace my-project --model claude-3-7-sonnet --thinking
```

#### Interactive Slash Commands

The interactive REPL intercepts slash commands locally without consuming LLM turns:

| Command | Description |
|---|---|
| `/help` | Show interactive command reference and shortcuts |
| `/workspace`, `/ws` | Display active workspace, list all (`/ws list`), or switch (`/ws switch <target>`) |
| `/model` | Show active model, list options (`/model list`), or switch (`/model switch <name>`) |
| `/session` | View session details, start new session (`/session new`), or view history |
| `/skills` | List bundled and user-installed agent skills |
| `/mcp` | List configured Model Context Protocol (MCP) servers and status |
| `/compact` | Trigger context compaction to prune conversation history while preserving context |
| `/steer <instruction>` | Redirect agent execution mid-turn at the next safe step boundary |
| `/queue <instruction>` | Queue a prompt to execute immediately after the current turn finishes |
| `/stop` | Cleanly interrupt an active turn (`Ctrl+C` also interrupts during turns) |
| `/clear` | Clear the terminal display |
| `/history` | View command history from `SANAD_HOME/cli_history` |
| `/thinking` | Toggle deep reasoning / thinking stream output on or off |
| `/exit`, `/quit` | Exit the REPL session (`Ctrl+D` on an empty line also exits) |

#### Interactive Permissions & Clarifications

When a tool requests approval for a sensitive action (such as executing shell commands or writing files), the REPL prompts for approval:
- `[y] Allow Once`: Grants permission for the single invocation (default).
- `[s] Allow for this Session`: Approves the tool for the lifetime of the session.
- `[w] Allow for entire Workspace`: Grants permission for all sessions in this workspace.
- `[n] Deny`: Rejects the tool invocation.

When the agent requires clarification via `system_ask_user`, an interactive choice menu is rendered with options and a write-in (`[w]`) answer mode.

### Headless Tasks & Unix Pipes

Execute one-shot tasks or pipe data through standard Unix pipelines:

```bash
# Direct one-shot prompt
sanad -p "Explain how DNS resolution works"
# or
sanad run "Scan lib/ for memory leaks"

# Pipe log output or source code into Sanad
cat debug.log | sanad run "Find the root cause of these errors"
git diff | sanad run "Generate a commit message following Conventional Commits"

# Machine-readable JSON output (ideal for scripts and automated CI workflows)
sanad run "Analyze dependencies" --json

# Quiet mode: outputs only the final assistant text, suppressing progress and banners
sanad run "Generate a UUID v4" --quiet
```

#### Headless Execution and Cancellation Policy

In headless non-interactive mode, sensitive tools requiring interactive permission are rejected by default. For a trusted, isolated invocation, `--allow-all-tools` explicitly auto-approves every gated tool for that run only; it does not modify the workspace's durable permission policy:

```bash
sanad run "Run test suite and fix failing tests" --allow-all-tools
```

`--timeout <seconds>` is accepted before or after `run`, defaults to 300 seconds, and accepts values from 1 through 86400. Timeout returns exit code `124`, SIGINT returns `130`, and SIGTERM returns `143`; each path requests one bounded Stop before cleanup. `--json` writes one result object to stdout, while diagnostics stay on stderr. `--quiet` writes only the final assistant text.

#### GitHub Actions

Use separate runner-temporary identity and state roots. Provision the selected provider's non-secret instance metadata in an organization-specific preceding step, and pass credentials only through protected GitHub secrets—never command arguments or workflow output:

```yaml
jobs:
  sanad-task:
    runs-on: ubuntu-24.04
    env:
      SANAD_HOME: ${{ runner.temp }}/sanad-home
      SANAD_STATE_HOME: ${{ runner.temp }}/sanad-state
    steps:
      - uses: actions/checkout@v6
      - uses: ./.github/actions/setup-fvm
      - run: fvm dart pub get
        working-directory: agent
      # Restore/provision provider metadata here without printing credentials.
      - name: Run Sanad and validate its JSON envelope
        working-directory: agent
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
        run: |
          fvm dart run bin/sanad_agent.dart run --standalone --json \
            --timeout 300 "Review this repository" > "$RUNNER_TEMP/sanad.json"
          jq -e '.exit_code == 0 and (.text | type == "string")' \
            "$RUNNER_TEMP/sanad.json"
```

The repository's own CI uses the secret-free deterministic E2E provider and `agent/tool/cli_aot_smoke.dart`; that fixture is strictly for automated verification, not normal user workloads.

### Workspace Management (`sanad ws`)

Workspaces isolate project files, skills, MCP servers, and security policies. The CLI automatically detects your active workspace by climbing parent directories from your current working directory (`CWD`).

```bash
# List registered workspaces with active marker (*) and policy
sanad ws list

# Show detailed information about the currently active workspace
sanad ws current

# Switch the active workspace in local CLI state
sanad ws switch <workspace-name-or-id>

# Register current or specified directory as a workspace
sanad ws add .
sanad ws add /path/to/project --name "My Project"

# Create a new directory and register it as a workspace
sanad ws create new-service --path ~/projects

# Display directory tree of active workspace
sanad ws tree
sanad ws tree src/components --max-entries 50

# View or update security policy mode (default or full_access)
sanad ws policy
sanad ws policy full_access
```

### Diagnostics & Inspection

```bash
# Verify environment health, Sanad Home, configuration, and daemon status
sanad doctor

# Inspect configured and supported AI models
sanad models

# Inspect configured AI providers
sanad providers
```

## Included skills

Every source or standalone Agent run installs the product-managed
`skill-creator`, `find-skills`, and `agent-browser` packages into the active
Sanad Home. The standalone download remains one executable and does not fetch
these skills from the network. Worktree and test runs use their isolated Homes.

Agent updates reconcile included skills only when the embedded bundle changes.
An unmodified managed skill can be updated or removed by a later release. A
skill edited by the user is preserved and becomes user-owned, and a skill the
user deleted is not silently restored. Workspace skills continue to override
user-level skills with the same name.

## Update Sanad

Packaged macOS and Windows Clients check the Stable signed Appcast after startup
and ask before installing a Client update. Windows releases remain temporarily
unsigned under the documented release policy, while WinSparkle DSA, canonical
release metadata, size, SHA-256, SBOM, and protected provenance remain required.
iOS uses Internal TestFlight, Android uses its user-approved system flow, and Web
loads the newer deployment on a later browser refresh.

On packaged Windows and macOS clients, consent-based automatic checks run in the
background and show a native update dialog only when a newer release exists.
Opening the application while it is current does not show an up-to-date dialog.
Use **Settings → General → Check for Updates** to request an interactive check;
that user-initiated flow may report that the Client is already current. When an
update is accepted, Sanad flushes Client-owned state and exits before the native
installer replaces the application.

Linux Client updates are deliberately manual:

1. Open **Settings → General** and select **Check for Updates**.
2. If a newer canonical Linux x64 `.deb` exists, Sanad opens that exact
   official GitHub Release artifact in the external browser. It does not
   download, replace, elevate, or restart the application.
3. Close the current Client and install the downloaded `.deb` with the software
   installer or `sudo apt install ./sanad-client-<version>-linux-x64.deb`.
4. Keep the existing Sanad Home (normally `~/.sanad`). Do not delete or replace
   it; identity, provider configuration, and Agent state remain there.

An up-to-date result or discovery failure does not prevent continued use.

To update a standalone agent from GitHub Releases:

```bash
sanad update
```

The updater selects the correct platform binary and verifies the release
metadata before replacing the installed executable. Release notes identify any
platform that requires a manual client update.

## Remove Sanad

Stop and unregister the agent service first:

```bash
sanad service uninstall
```

Then remove the client using the normal application-removal flow for the
platform. Removing the application does not implicitly delete user workspaces.
Review the release documentation before deleting Sanad's local application
data.

## Security and troubleshooting

- Never publish provider credentials, account tokens, device tokens, or user
  content in an issue.
- Report vulnerabilities using [SECURITY.md](../../SECURITY.md).
- See [Sanad Agent Features](../product/features.md) for supported behavior.
- Developers building from source should use the
  [Developer Guide](developer_guide.md).
