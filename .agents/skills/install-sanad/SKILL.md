---
name: install-sanad
description: Install, update, or prepare Sanad for normal use or source development on macOS, Windows, or Linux. Use when an AI agent must inspect a machine for an existing Sanad installation or checkout, explain the release-user and developer-source paths, install the Client and local Agent, install an Agent on a remote server, update packaged components, or safely update and run a development checkout.
---

# Install Sanad

Guide the user from inspection through a verified Sanad installation or update.
Keep the release-user and developer-source workflows separate.

## Safety Rules

- Inspect before changing anything. Treat installation, package replacement,
  service registration, application launch, and Git updates as mutations that
  require the user's informed approval.
- Never search an entire home directory or disk for a checkout. Inspect the
  current directory, a path supplied by the user, and standard installed-command
  locations only. Ask for the project path when it cannot be identified safely.
- Never overwrite, reset, clean, stash, commit, or discard a dirty repository
  unless the user explicitly authorizes that exact action.
- Never request, quote, log, or reconstruct a pairing token, access token,
  refresh token, provider credential, signing secret, or user content.
- Use only official Sanad sources:
  - repository: `https://github.com/EastStarAI/sanad-agent`
  - releases: `https://github.com/EastStarAI/sanad-agent/releases/latest`
  - installers: `https://sanad.eaststarai.com/install.sh` and
    `https://sanad.eaststarai.com/install.ps1`
- Do not disable operating-system security controls. Read the latest release
  notes before describing current signing or platform support.
- Preserve Sanad Home and user workspaces during installation and update.

## 1. Inspect the Target

Establish whether commands will run on the user's current machine or a remote
machine. Do not assume that the machine hosting Sanad Client is the machine that
should host Sanad Agent.

Collect read-only evidence:

1. Identify the operating system and architecture.
2. Check whether `sanad` and `sanad-dev` resolve on `PATH`.
3. Check the installer-owned executable when relevant:
   - macOS/Linux: `${SANAD_HOME:-$HOME/.sanad}/bin/sanad`
   - Windows: `$env:SANAD_HOME\bin\sanad.exe`, or
     `$HOME\.sanad\bin\sanad.exe` when `SANAD_HOME` is unset.
4. If the current or supplied directory is a Git checkout, inspect:
   `git rev-parse --show-toplevel`, `git remote -v`, `git status --short
   --branch`, and `git worktree list`. Accept it as Sanad source only when its
   repository identity matches `EastStarAI/sanad-agent` or the user confirms an
   intentional fork.
5. Query installed versions and service status only through a resolved Sanad
   executable. Do not fail merely because `sanad` is absent from `PATH`.

Summarize what exists before proposing a change.

## 2. Select the Workflow

If the user's request already makes the workflow explicit, confirm the target
and continue. Otherwise present these choices and ask which one they want:

| Path | Best for | Result | Tradeoff |
|---|---|---|---|
| Release / user | Normal daily use | Packaged Client and verified Agent release | Stable and simple; source is not editable |
| Source / developer | Contributing, debugging, or changing Sanad | Repository checkout run through `sanad-dev` | Editable and testable; requires development tools and more disk space |

For the release path, determine the topology:

- **This desktop:** install Sanad Client; **Run Locally** installs and starts the
  matching Agent on the same computer.
- **Another computer or server:** keep the Client on desktop, mobile, or web and
  install only Sanad Agent on the target machine.
- **Client only:** install a desktop/mobile Client or use the Web Client without
  installing an Agent on that device.

State the exact actions, destinations, and service impact. Obtain approval
before downloading, installing, replacing, registering, starting, or restarting.

## 3. Release / User Path

### Install the Client and Local Agent

1. Read the latest official release and its manifest. Select only the Client
   package matching the confirmed platform and architecture.
2. Verify the artifact using the checksums, signatures, and platform guidance
   published by that release. Do not generalize an older release's signing
   status to the current release.
3. Install the Client using the normal operating-system flow. Do not silently
   bypass application-review or security prompts.
4. Ask the user to launch Sanad Client and choose **Run Locally**. Explain that
   the Client downloads, verifies, registers, starts, and connects to the
   matching local Agent; a Sanad account and pairing token are not required.
5. Verify that the Client can reach the local Agent before declaring success.

For Android, iOS, and Web, follow the availability stated in the current
release notes. These platforms provide the interface but do not host the native
Agent service.

### Install an Agent on Another Computer or Server

Offer two equal choices:

1. **Pair through Sanad Client:** direct the user to **Device Management → Add
   device** and have them run the complete generated command on the target
   machine. Do not ask them to paste its embedded credential into the AI chat.
2. **Install the Agent directly:** choose Portal sign-in or local-only mode and
   run the matching official installer after approval.

For an agent-operated macOS/Linux terminal, avoid an ambiguous prompt:

```bash
curl -fsSL https://sanad.eaststarai.com/install.sh | bash -s -- --login
```

Use `--no-login` instead when the user explicitly chooses local-only mode.

For an agent-operated Windows PowerShell terminal:

```powershell
& ([scriptblock]::Create((irm https://sanad.eaststarai.com/install.ps1))) -Login
```

Use `-NoLogin` instead when the user explicitly chooses local-only mode. A
human running either installer interactively may omit the explicit login option
and answer its prompt.

Portal sign-in may require the user to open a URL or enter a code. Pause for
that human action without exposing returned credentials. After installation,
verify the resolved executable's version and `service status`. Confirm the
device from Sanad Client when cloud connection was selected.

### Update a Packaged Installation

1. Inspect the installed Client and Agent versions and read the latest release
   notes before changing them.
2. Update Sanad Client through its platform-owned update flow. Do not replace a
   packaged Client with source output.
3. Update a standalone Agent through the resolved executable:

   ```bash
   sanad update
   ```

   Use the full executable path when `sanad` is not on `PATH`. If the updater
   reports `restart_required`, obtain approval and run `sanad service restart`.
4. Verify the final version, service state, Client-to-Agent connection, and the
   preservation of Sanad Home. Report any platform step that remains manual.

## 4. Source / Developer Path

### Prepare the Checkout

If a matching checkout already exists, use it only after reporting its path,
branch, worktree, remotes, and dirty state. Do not clone a duplicate silently.

If no checkout exists, propose a destination and obtain approval, then run:

```bash
git clone https://github.com/EastStarAI/sanad-agent.git sanad-agent
cd sanad-agent
```

Read the repository `AGENTS.md`, `docs/llms.txt`, and the closest nested
contracts before further work. Use FVM for every Dart or Flutter operation.

Install the user-scoped development command once.

On macOS/Linux:

```bash
scripts/sanad-dev install
```

On Windows PowerShell:

```powershell
.\scripts\sanad-dev.ps1 install
```

Then run the matched Agent and Client pair on every platform:

```bash
sanad-dev run
```

Use `sanad-dev run --no-cloud` only when the user explicitly wants local-only
development. Use `sanad-dev status` and bounded `sanad-dev logs agent -n 50`
and `sanad-dev logs client -n 50` calls for verification. Never use log follow
mode from an AI tool call.

### Update a Developer Checkout

1. Inspect the active branch, upstream, worktrees, and dirty files.
2. Run `git fetch` only after confirming the intended remote. Explain incoming
   commits before integration.
3. For a clean checkout on the intended tracking branch, propose
   `git pull --ff-only`. Do not create merge commits implicitly.
4. For a dirty checkout, stop and present preservation options. Do not stash,
   commit, rebase, switch, reset, or discard without explicit authorization.
5. After a successful source update, rerun the platform-specific
   `sanad-dev install`; then use `sanad-dev run` or the user's requested bounded
   verification command.
6. Never use `sanad update` for a source/FVM runtime; source updates belong to
   Git and `sanad-dev`.

## 5. Report the Result

Report:

- selected workflow and target machine;
- detected and final versions;
- Client, Agent, repository, and service state;
- verification commands and outcomes;
- any manual user action still required;
- files, services, or Git state changed.

Never claim success from a download or command exit alone. Require the relevant
service or Client-to-Agent health evidence. Do not commit, push, publish, or
remove user data unless the user requested that separate action explicitly.
