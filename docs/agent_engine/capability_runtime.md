---
title: "Capability Runtime Architecture"
description: "Architecture of tool specifications, runtime catalog assembly, permissions, MCP, workspace/web services, skills, and platform tools."
---

# Capability Runtime Architecture

## Layers

The capability domain separates LLM-facing schemas from rich runtime metadata,
execution services, approval policy, and external catalogs:

- tool schemas describe model-visible names and JSON parameters;
- local tool specifications add source, target, availability, workspace,
  approval, and replay-safety metadata;
- the tools registry provides execution lookup and searchable catalog access;
- the per-turn runtime catalog merges built-in, workspace, MCP, skill, web, and
  explicitly supplied platform capabilities;
- permission policy gates sensitive execution and persists suspended approval;
- focused workspace/web handlers execute host operations;
- the MCP manager owns merged configuration, owner-protected credentials, real inspection, OAuth discovery/PKCE/callback lifecycle, and persistent server sessions; clients receive only redacted snapshots, opaque flow IDs, authorization URLs, and typed states.

## Per-Turn Assembly

Workspace instructions, workspace-bound tools, merged MCP state, and platform
contracts are rebuilt for each turn so mutable runtime configuration remains
current. Runtime context loads the nearest workspace contracts first, sanitizes
instruction content, omits tool inventory prose, and applies head-plus-tail
truncation under prompt budget. When no valid workspace is attached, the context
instead states concisely that file and terminal tools are unavailable and directs
workspace-dependent requests to the workspace control in the upper-left corner.
Runtime context includes a date-and-zone awareness line (no clock time, byte-stable within a day) derived in the schedule's resolved timezone, while turn-specific execution timestamps belong to the engine's volatile prompt tier.

## Tools

Built-in tools implement one execution boundary with optional `ToolContext`.
Replay safety is explicit metadata and defaults to unsafe. Read-only searches
may opt into restart replay; file mutation, shell execution, scheduling,
delegation, and permissioned platform actions remain unsafe unless their exact
contract proves otherwise.

Workspace file operations are implemented by focused read/write/edit/search
handlers. `file_edit` supports single find-and-replace (`old_string`/`new_string`)
and atomic multi-chunk replacements (`edits`). Multi-chunk edits validate all chunks,
verify uniqueness unless `replace_all` is set, and reject overlapping ranges before
modifying the file on disk; non-overlapping matches are applied in reverse order
(bottom-to-top) to preserve preceding text offsets and line positions. The result
payload reports `numEdits` plus `editStartLines` (per-chunk start lines aligned with
the `---`-separated hunks in `patch`) so presentation layers can position each chunk
without guessing. Paths are
canonicalized before host access. Targets inside the selected workspace execute
directly; targets outside it execute directly only in `full_access` mode, while
`default` mode suspends the turn for user approval. Remembered grants are scoped
by tool plus canonical target. Approval cards expose only the action and canonical
path, while durable checkpoints retain the original arguments required to resume
safely. External results use absolute paths and internal results remain
workspace-relative. Recursive glob/grep discovery omits common generated, cache,
build, and dependency trees such as virtual environments, `site-packages`, `.next`,
`dist`, and `target`. A candidate that passes binary sniffing but cannot be decoded
as UTF-8 is skipped without failing the whole search. Shell execution follows
host-native command semantics, enforces workspace/path and permission policy,
applies a bounded timeout, bounds stdout and stderr while streaming, and terminates
the command process tree where supported. Child processes are not trusted to emit
valid UTF-8: malformed byte sequences are replaced during bounded decoding rather
than escaping the tool future and terminating the Agent daemon.

## Tool Output Budgets

The engine tool-execution boundary applies a provider-neutral output guard after
every built-in, workspace, MCP, platform, or future registered tool returns and
before emitting completion events, writing checkpoints, or appending model
history. One result is limited to 50,000 characters and the aggregate results
from one tool-call batch are limited to 100,000 characters. Truncation preserves
head and tail content and includes original and omitted character counts.

Producer-side limits remain necessary where post-return truncation would be too
late to protect daemon memory. Shell streams retain bounded head/tail windows;
file reads enforce 2,000-line and 50,000-character pages with continuation
metadata; grep clamps result/context counts, individual lines, and accumulated
content. Model-visible schema maximums are advisory, while the corresponding
runtime clamps are authoritative.

Oversized raw results are not persisted as workspace-readable artifacts. Sanad's
workspace reader intentionally cannot access daemon-private temporary storage,
and silently writing result files into a user workspace would violate the
non-mutating behavior expected from read-only tools.

## Permissions

Permission policy combines workspace rules with once, session, and workspace
user decisions. Before a sensitive call waits for approval, the manager writes a
durable suspended checkpoint containing enough identity and tool context for
restart. A resumed decision is reapplied before execution; a once decision uses
a one-shot bypass to avoid immediately prompting again. Concurrent authorization
checks are serialized FIFO per session so the client and durable session state
never have more than one unresolved interactive permission request for that
session. Each queued check re-evaluates current policy when it reaches the front,
while checks from different sessions remain independent. Daemon-backed E2E
verification drives a parallel external-file-read batch through the authenticated
local socket and requires each permission response before the next request is
emitted.

## MCP and Skills

MCP settings merge user and workspace scopes. Enabled stdio, SSE, and
streamable-HTTP servers use persistent managed sessions with configuration
fingerprints for tool-spec caching and reconnect/retry after connection loss.
The daemon remains the source of truth for snapshots and mutations exposed to
clients.

MCP configuration management is local-only while the remote-management
security review remains open. The cloud adapter rejects remote list, inspect,
save, delete, and whole-config replacement requests before shared bridge
dispatch. This admission boundary does not alter per-turn catalog assembly:
servers configured by the local user remain available for tool discovery and
execution in both local and cloud-origin turns.

Skills are discovered and loaded by the runtime skill registry. Product skills
share the repository's `.agents/skills/` source with development skills; a
selective manifest chooses which complete packages are converted into
compressed Dart data and compiled into the single Agent executable. On first
run, or after the compiled bundle revision changes, the daemon reconciles those
packages into `<SANAD_HOME>/skills/`. An unchanged start reads only the small
managed-state revision and does not walk or hash skill directories.

The lifecycle manager records the origin hash it installed. It updates or
removes only content that still matches that origin, preserves collisions and
user-modified packages as user-owned, and respects a user's deletion. Package
replacement uses a staged directory and recoverable backup, while recursive
delete requires a canonical strict child of Sanad Home. Reconciliation failure
does not advance the bundle revision and does not prevent daemon startup.
Source, standalone, worktree, and test runs use the same manager and differ only
by their active `SANAD_HOME`.

A successful `skill_load` result contains one source-path header followed by
the original skill Markdown; model-visible results omit duplicated input,
frontmatter, provenance, and shadowing diagnostics. The user-scope registry
reads `<SANAD_HOME>/skills` before compatibility roots. Workspace roots retain
higher precedence. The client does not inspect skill files to determine runtime
availability.

### Third-party skill installs

`sanad skills` is the CLI surface for user-installed skills; it is not the
product bundle lifecycle. `add` fetches a public GitHub repository as a
`.tar.gz` over HTTPS (no `git` binary and no credentials) or reads a local
directory, then discovers either a root `SKILL.md` or `skills/<name>/SKILL.md`.

The installer writes `<SANAD_HOME>/skills/<name>`. Passing the shared
`--workspace <path|name>` option instead targets `<workspace>/.sanad/skills/<name>`,
which is one of the workspace roots the registry already scans. The value may be
a directory or the name of a registered workspace. The archive reader
rejects absolute paths, `..` segments, links, and payloads beyond its size caps
before anything is written; installation is staged and renamed, and an existing
skill is never replaced without `--force`. A `SKILL.md` whose declared `name`
contradicts its directory is rejected.

Provenance is recorded per skills root in `.sanad-skills.json`, deliberately
separate from the product-owned `.sanad-managed.json`. `remove` and `update`
operate only on entries in that file, so bundled packages and hand-copied skills
are never deleted or overwritten by this command.

The daemon is not involved in the install itself. Because the skill registry
scans these roots per request, an installed skill becomes available on the next
turn without a restart, and bundled reconciliation leaves user-installed
packages untouched.

Installation, updates, and removal enforce strict destructive path and content
safety boundaries. `remove` validates package names, rejects symbolic links,
and verifies through link resolution that targets are strict descendants of the
active skills root. `update` inspects the on-disk directory digest against the
recorded provenance digest, preserving local modifications and skipping updates
unless `--force` is supplied. Staged content is scanned before activation for
credential paths, piping remote content to shells, encoded execution, exfiltration,
destructive filesystem operations, permissive chmod, instruction overrides, and
secret-harvesting phrasing; flagged packages are refused unless explicitly permitted
via `--allow-flagged`, and the screening verdict (`clean` or `flagged`) is recorded
in provenance. Publishers may declare authorized remote hosts in `SKILL.md` frontmatter
under `metadata.allowed_remote_exec`. For host-scoped rules (`remote-exec`, `encoded-exec`,
`exfiltration`), findings are suppressed when all URL hosts on the matched line are covered
by that file's declaration (exact domain and subdomain match, e.g. `example.com` covers
`cdn.example.com`). Lookalike suffixes, userinfo tricks, IP literals, bare localhost,
relative paths, and undeclared hosts remain blocked. Rules that are not host-scoped
(credential paths, destructive filesystem commands, chmod 777, instruction overrides,
secret harvesting) are never suppressed. Packages passing solely through declared host
allowances record the distinct verdict `allowed` and their declared host list in provenance.

## Platform Tools

Platform-provided tools are explicit, turn-scoped contracts. Their specifications
retain platform source and execution target metadata. Invocation and result
travel through canonical platform call/result protocol and are never executed
as local daemon implementations.
