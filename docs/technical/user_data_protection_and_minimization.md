---
title: "Local Gateway and Sanad Home Protection"
description: "Authentication, origin enforcement, filesystem ownership, secure startup, and runtime isolation for local Sanad data."
---

# Local Gateway and Sanad Home Protection

## Threat Boundary

The Local Gateway is a desktop-only transport. Flutter Web, mobile, and every
remote client use the hosted gateway and never read a local credential or
attempt a Local Gateway connection.

The local boundary protects Sanad from browser origins, LAN peers, and other
operating-system accounts. A process already running as the same operating-
system account is inside the v1 local trust boundary because it can read any
file that account owns. Protecting against a compromised same-account process
would require an operating-system broker or separately enrolled client identity
and is not represented by a shared filesystem credential.

## Local Gateway Admission

The daemon binds only a literal loopback address. Wildcard, private-network,
link-local, and public addresses fail startup rather than falling back to a
different interface.

Every HTTP route and WebSocket upgrade requires the credential stored in
`.local_token` under the active Sanad Home. Native desktop consumers and
`sanad-dev` read it from that same Home and send it in the
`x-sanad-local-token` header. The credential never enters a URL, query string,
compile-time define, process argument, preference store, response, or log.

Every request also supplies a valid loopback `Host` for the configured port.
If an `Origin` is present, it must match the explicit native/development
allowlist. A missing `Origin` is acceptable only for an authenticated native
loopback request; it never grants authority on its own. Browser-facing local
requests are not a supported product mode.

The native desktop authentication exchange sends only an exact notification
with no payload fields. It causes the daemon to reload owner-only `auth.json`
and never returns a credential; unexpected fields are rejected before payload
logging.

WebSocket admission has two bounded stages: unauthenticated upgrade work is
reserved before the upgrade and released when the handshake succeeds or fails;
exhausting the per-peer reservation budget installs a short bounded cool-down.
Neither limit affects the lifetime or number of already authenticated
application sockets.

## Credential Lifecycle

The credential contains 32 cryptographically random bytes encoded without
padding-sensitive transport semantics. It is stable for one Sanad Home so the
daemon, desktop client, and developer launcher can restart independently. A
missing or invalid credential is regenerated through the secure write boundary.
The file is owner-readable only and its content is never returned by daemon
discovery endpoints.

## Filesystem Roots

`SANAD_HOME` owns identity, configuration, provider secrets, the Local Gateway
credential, and—during normal and worktree-managed execution—runtime state.
External tests may select a distinct `SANAD_STATE_HOME`; in that case the same
boundary is instantiated for both roots and the roots must be distinct,
non-overlapping real directories.

The configured root itself cannot be a symbolic link. A child operation rejects
absolute paths, traversal, null bytes, symbolic-link components, and targets
outside its selected root. Directory creation and startup preparation do not follow
symbolic links.

Directories are owner-only (`0700`) and sensitive files are owner-only (`0600`)
on Unix-like systems. Windows removes inherited and explicit access for other
principals and grants full access to the current user only. Ownership or ACL
failure is fatal before payload access continues.

## Writes and SQLite

Ordinary Sanad Home files use one atomic writer. It creates an unpredictable,
exclusive temporary file in the destination directory, applies ownership
before the first payload byte, flushes the file, replaces the destination
atomically, and cleans the temporary file on every failure. Existing
destinations and path components are revalidated before activation.
Cross-process read-modify-write owners use a stable owner-only lock inode opened
through the same boundary. The Linux owner-file Agent credential backend uses
this lock plus the atomic writer; its filesystem mode protects against other
operating-system accounts but is not encryption.

SQLite is the deliberate exception to routing each byte through the atomic
writer. The boundary secures the state directory and existing database before
opening SQLite, then validates and tightens `state.db`, WAL, SHM, and journal
sidecars after opening and schema initialization. SQLite remains the only
writer of its transactional files.

## Startup Preparation

Bootstrap runs before dependency composition, authentication reads, provider
secret reads, or database open. It creates missing roots securely and rejects
symlinked or overlapping roots, but never walks the complete Sanad Home tree.
Sanad has no installed-user legacy population, so startup carries no recursive
migration framework or version marker.

Every daemon-owned file is secured at its actual ownership boundary: new paths
inherit the owner-only process mask, atomic writers secure destinations before
payload publication, reads reassert the target mode before returning bytes,
and SQLite secures its database plus sidecars around connection initialization.
On Unix, permission enforcement checks the existing mode before spawning
`chmod`, so already-correct targets incur metadata validation only. A
supervised source daemon leaves root preparation to its child; direct daemon
entry points still prepare the roots before dependency composition.

## Isolation

The primary checkout and packaged application use the ordinary user Sanad Home.
Each linked `sanad-dev` runtime uses one worktree-scoped Home shared by its
daemon and desktop client. Its Local Gateway credential, identity, database,
memories, dumps, launcher records, and client preference namespace remain inside
that isolation boundary. Owner-only runtime discovery metadata remains in the
shared developer runtime directory so `sanad-dev` can discover isolated pairs;
it records each pair's Home without containing the credential. Tests use
temporary roots and never read or mutate the real user Home. The default
on-disk agent-state constructor detects the Dart test runner and fails before
filesystem access unless the test has explicitly selected a temporary home or
state home. Tests that do not need persistence inject an in-memory database;
tests that exercise persistence use an explicit temporary path.
