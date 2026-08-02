---
title: "Install and Use Sanad Agent"
description: "Install the Sanad client and agent, connect local or remote devices, configure providers, manage the service, and update Sanad."
---

# Install and Use Sanad Agent

Sanad has two components:

- **Sanad Client** is the Flutter interface for desktop, mobile, and web.
- **Sanad Agent** is the native background service that runs on macOS, Linux,
  or Windows and owns workspace execution and local state.

For a normal desktop setup, install the client and let it connect to the agent
on the same computer. For a server or another computer, install the standalone
agent and pair it with your account.

## Install Sanad Client

Open the [latest Sanad Agent release](https://github.com/EastStarAI/sanad-agent/releases/latest)
and choose the client package for your platform:

| Platform | Package |
|---|---|
| macOS | `sanad-client-<version>-macos-universal.dmg` |
| Windows | `sanad-client-<version>-windows-x64.exe` |
| Linux | `sanad-client-<version>-linux-x64.tar.gz` |
| Android | `sanad-client-<version>-android-universal.apk` |
| iOS | Internal TestFlight invitation only for the first release |
| Web | [app.sanad.eaststarai.com](https://app.sanad.eaststarai.com) |

### macOS

1. Open the versioned macOS DMG.
2. Drag Sanad Client to Applications.
3. Launch Sanad Client and approve the operating-system prompts required by the
   features you choose to use.

### Windows

The `1.0.0` package is an **Unsigned Windows build**. Download it only from the
official release, compare its SHA-256 with the published release manifest, and
then run the versioned Windows x64 installer. Do not disable Microsoft Defender
or Smart App Control. If SmartScreen warns after origin and hash verification,
use the operating-system review flow to inspect the publisher status before
choosing whether to continue. The `1.0.0` clean-machine release gate was
validated on Windows 11. Windows 10 was not validated and no Windows 10 test
result should be inferred from the shared x64 package.

After installation, launch Sanad Client from the Start menu.

### Linux

1. Extract the versioned Linux x64 bundle.
2. Open the extracted bundle.
3. Run the Sanad Client executable.

The release notes list any distribution-specific desktop integration
requirements.

## Use Sanad locally

On desktop, choose the local-device path during setup. The client connects
directly to the agent on the same computer.

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
4. Copy the generated command and run it once on the target computer or
   server. The command installs, pairs, and starts the agent.

For macOS or Linux:

```bash
curl -fsSL https://sanad.eaststarai.com/install.sh | bash -s -- --pairing-token '<pairing-token>'
```

For Windows PowerShell:

```powershell
& ([scriptblock]::Create((irm https://sanad.eaststarai.com/install.ps1))) -PairingToken '<pairing-token>'
```

The installer detects the operating system and architecture, reads the public
release manifest, verifies the selected artifact, installs the `sanad` command,
prepares the initial pairing state, and starts the background service. The
pairing token is visible in the copied command, but it is not the durable
device credential: the agent generates that credential locally and the
Gateway invalidates the visible token on the first successful connection.

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
4. Pair a remote device when needed by pasting the creation token shown by
   **Add device**:

   ```bash
   sanad login --token '<pairing-token>'
   ```

5. Install and start the background service:

   ```bash
   sanad service install
   ```

## Manage the agent service

The same service commands are available on macOS, Linux, and Windows:

```bash
sanad service status
sanad service start
sanad service stop
sanad service uninstall
```

Closing Sanad Client does not stop an installed agent service. Active or
scheduled work can continue on the device while the service is running.

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

## Update Sanad

Sanad Client checks the update channel supported by its platform and prompts
before installing an application update. macOS uses its signed Appcast. The
unsigned Windows `1.0.0` path must verify official release metadata and SHA-256
before replacement; release notes state whether that client update is automatic
or manual. Linux and Android use a user-approved system flow, iOS uses Internal
TestFlight, and Web loads the newer deployment on the next browser refresh.

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
