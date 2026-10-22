# Sanad 1.0.18

Sanad 1.0.18 turns remote delegation into a first-class workflow, makes execution authority and secret handling explicit and scoped, and closes a long list of reliability defects in compaction, session history, and the desktop Client.

## Reliability

- **Compaction targets a whole request.** Compaction now aims at a whole-request target and runs a pre-send fit check, so the next request (system, tools, summary, retained tail) fits the model window before it is sent (#247). Compaction passes get their own response budget, overflow compaction respects the per-run breaker, and a failed summary no longer leaks provider text or loses attempt usage (#236).
- **No false compaction failures.** A manual `/compact` that outlives the gateway request window reads as pending and then reports its real outcome, instead of showing an error toast while the compaction keeps running (#228). A session that restarted mid-compaction no longer stays locked out of compaction, and token estimation is calibrated against the real window (#210).
- **Waits and history survive restarts.** A conversation parked on a user-input question or a pending permission prompt keeps that wait across a managed restart and a forced kill (#215). History rewrites update rows in place, so message identity, compaction boundaries, and completed compaction state survive image pruning, provider-state clearing, and steer stamping; recovery summarization is bounded per pass (#233).
- **Earlier answers keep their footer.** Final answers retain their tokens/model/duration footer and the Fork control after reload, because terminal classification is session-scoped and the terminal stamp is no longer erased by a stale cached rewrite (#238). Fork markers and automatic-failover notices appear exactly once, at the position they had live, on every reload and history page (#241).
- **Provider routes stop failing long runs.** Each request is projected into the destination route's valid wire form across mixed-provider tool history (#232), OpenCode Go models are dispatched on their per-model wire protocol (#234), and same-route tool turns replay an empty `reasoning_content` where the route requires an echo (#251).
- **A Client always lands on a usable device.** A remembered device that cannot appear no longer leaves the Client waiting indefinitely, a cloud reconnect repairs itself without a restart, and a failed request is never presented as an empty success (#248).

## Windows

- **Non-ASCII shell arguments arrive intact.** The Windows execution wrapper switches to UTF-8 code page 65001 before running the command, so Arabic and other non-ASCII arguments no longer reach the child as mojibake; `shell_execute` also reports `exit_code` when the command exits on its own (#255).

## Remote delegation

- **`sanad-client` remote relay.** A canonical `device.cli.execute` contract with streamed stdout/stderr/event events, one terminal result, cancel forwarding, and Home-scoped discovery; one CLI owner per Sanad Home; a disabled-by-default loopback host with an owner-only runtime record; `default` and `full_access` modes approved through the existing Client permission surface; local-device exclusion; and fail-closed behaviour when nothing owns the Home (#188).
- **Relay behaves predictably.** The relay window follows `--timeout` (plus a 30 second margin, 300 second default) instead of a fixed 300 seconds; a background run started with `--brief-file`, `--prompt`, or a positional prompt no longer waits on an open stdin, and host-local input uses `--stdin`; a pending approval prints one status line; and a relay that ends without a terminal result exits 1 with a diagnostic instead of reporting success (#256).
- **Remote workspace picker.** A Client connected over the cloud can browse, pick any nested folder, and create, rename, and delete folders inside `<SANAD_HOME>/workspaces`. The Agent enforces the confinement itself and never trusts the Client; local connections keep the native macOS picker (#239).
- **Supervised delegation to another device.** The supervisor accepts `sanad-client -d <device-id> run ...` tasks, streams relay stdout into the run directory, reuses the local timeline handler, and maps exit codes 124, 130, 69, and 77 to timeout, cancelled, and blocked, with a missing envelope treated as incomplete (#252).

## Security and secrets

- **Command authority is scoped per turn.** Workspace permission authority is daemon-private, each turn records its own command authority in session metadata, the authenticated cloud client is trusted like the local client, and protected or unreadable policy is refused before approval (#245).
- **Children get the policy environment and nothing else.** Shell and MCP children spawn with exactly the policy environment; `.env` redaction gaps are closed; Git config injection and interpreter path overrides are rejected (#245).
- **Workspace policy is one scope per folder.** Policy scope is derived from the validated tool root, duplicate records of one folder are a single scope, removed workspaces delete their policy, and policy changes (grants included) are announced to every client. `sanad ws policy` shows execution mode and host discovery, and the Client gets a localized Full Access confirmation and workspace security settings (#245).
- **Secrets are requested, never inferred.** User-provided secrets live in a dedicated vault namespace; `shell_execute` injects only the secret names the call lists explicitly; responses resolve through an owner-only, value-free boundary that never carries a value back through the model or a tool result; request, list, and delete tools are owner-only; values are collected in a localized masked composer card; and the terminal CLI never answers a secret request (#246).
- **Skill installs stay screened.** A skill declares the remote hosts its installer may execute and the install path honours that declaration; anything undeclared stays blocked (#222).
- **`--home` is honoured before any Home access.** A `sanad … --home <dir>` invocation can no longer migrate the default Home or move its provider and MCP secrets, and an inherited `SANAD_STATE_HOME` no longer splits identity from state (#249).

## Command line

- **Skills lifecycle.** `sanad skills list|add|remove|update` installs a third-party Agent Skill from a public source with recorded provenance, collision protection, and content screening, needing no `git` binary or credentials (#220).
- **Schedules.** Recurring schedules are created, listed, updated, and cancelled through one `schedule_task` tool that also reports the active zone, and `sanad schedule list` is a real read-only listing (#240).
- **Updates and services.** `sanad update` prints the failed trust stage plus platform-appropriate installer guidance, the new read-only `sanad service definition` reports the installed service definition, and version and help queries no longer create or change a Home (#242).
- **Multi-chunk file edits.** `file_edit` accepts several non-contiguous chunks in one atomic, pre-validated call with overlap detection and preserved CRLF/LF endings, while single-edit calls stay unchanged (#216).

## Client interface

- **Navigation lands where you asked.** Back and Forward reach the intended conversation instead of falling back to a New Conversation when the target sits outside the loaded pages (#217).
- **One tray icon.** The tray exposes a single icon per process using the platform menu-bar artwork, instead of leaking one icon per restart and rendering an opaque square (#218).
- **macOS stays running.** Closing the window no longer terminates the app: the Client keeps its sockets, Agent link, and CLI endpoint, and reopens from the Dock (#221).
- **One input path for files and media.** Paste, drop, and the `+` picker share a single router, macOS Cmd+V image and file pasting works again, Shift+Enter newlines are preserved, file references render as inline chips, images open in a lightbox with download and a media cache, and remote attachments are disclosed (#244). Tool image results are typed and durable through `view_image` and a hosted media relay, so a Client on another device can attach an image and fetch accepted media (#201).
- **Drafts keep their route.** A New Conversation draft keeps its provider route and explicit thinking level across restart instead of blocking Send until a model is picked again (#231).
- **Edits and diffs read correctly.** Multi-chunk edits render each hunk at its real position, and the file tool tile no longer prints per-event diagnostic blocks (#219).
- **Mobile authorization stays in the app.** Portal authorization opens in an in-app browser that closes after the callback, with connect and receive timeouts long enough for a slower network to finish the token exchange (#227).

This release was built from tagged public source by the protected Sanad release workflow. Verify downloads against `SHA256SUMS`, `release-manifest.json`, and GitHub build provenance before installation.

> [!WARNING]
> **Unsigned Windows build:** Sanad Agent and Sanad Client `1.0.18` artifacts for Windows x64 intentionally do not carry Authenticode signatures. Windows Defender or SmartScreen may show an unknown-publisher warning. Download only from this official `EastStarAI/sanad-agent` release, verify the manifest, file size, SHA-256, and GitHub provenance, and do not disable platform protection. Windows release gates run on Windows 11; Windows 10 has not been validated. The Client update package remains signed separately with WinSparkle DSA; that update signature is not Authenticode and does not establish a Windows publisher.

macOS and Android artifacts use their documented platform signatures. Linux and Windows artifacts are bound to the release through checksums, the immutable manifest, SBOM, and GitHub attestations.

> [!NOTE]
> **iOS Internal TestFlight only:** The iOS artifact for `1.0.18` is distributed exclusively to internal TestFlight testers of the `NanoSoft LY LLC` team. It is not included in public downloads and is not available through the public App Store. Build number `19` corresponds to marketing version `1.0.18`.
