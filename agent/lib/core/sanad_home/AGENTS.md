# Sanad Home Boundary Contract

## Scope
This contract applies to `agent/lib/core/sanad_home/`.

## Mission
Provide the single boundary helper that owns the canonical Sanad Home
path, atomic writes, and ownership enforcement for every file under
`SANAD_HOME`. SEC-02 (Local Gateway & Sanad Home boundary) requires that
no writer outside this helper reaches the filesystem.

## Ownership
- `SanadHomeBootstrap` resolves the canonical home, asserts the resolved
  path stays inside the configured root, refuses `..` and symlink
  escapes, and applies owner-only permissions before any byte is written.
- `InstalledHomeRecord` is the single owner of "the Home this executable was
  installed into". `scripts/install.sh|install.ps1` place the artifact at
  `<home>/bin/sanad` and `service install` records the non-secret
  `<home>/service.json` beside it, so that pair is the only local evidence of
  which Home a binary serves. The probe stats the record with
  `followLinks: false` and returns no Home for a source run, a copy outside a
  Home, a Home without the record, or a symlinked record; it never reads `.env`,
  a credential, or any file content, and it creates nothing.
- `LoopbackPolicy` is the single authority for "is this address
  loopback"; it rejects `0.0.0.0` and `::` as wildcard and accepts only
  literal loopback values.
- `SanadHomeBoundaryViolation` and `SanadHomeWriteFailure` are the typed
  error surface; callers convert them to transport-level responses
  without logging the path or the secret bytes.

## Critical Invariants
- Every daemon-owned regular file under `SANAD_HOME` or `SANAD_STATE_HOME`
  MUST flow through the root-scoped `SanadHomeBootstrap` read/write boundary.
  Managed directory replacement stages a complete strict-child tree, retains a
  recoverable backup until commit, rejects symlinks, and permits recursive
  deletion only for a canonical strict child of the configured root.
  SQLite is the sole exception: its owner brackets the native connection with
  `prepareDatabase` and `secureDatabaseFiles`.
- Temp files are created with `0600` (Unix) or the current-user ACL
  (Windows) BEFORE any byte is written, then atomically renamed.
- Cross-process file-backed mutations use a stable owner-only lock file created
  and opened by `SanadHomeBootstrap`; callers never replace a lock inode while
  another process may hold it. The daemon and in-process CLI hold one shared
  state-root runtime-ownership lease before any SQLite connection opens.
- The runtime-ownership lease records its holder: pid, inherited launcher
  id/nonce, and acquisition time, in `.runtime-owner.json` written atomically
  through the boundary. It is best effort and never fails an acquisition that
  already won the lock, it contains no credential, and a reader treats a record
  whose pid is gone as stale. A conflict message names the holder when it is
  readable — the lock file itself stays anonymous.
- The supervisor lease check (`supervisor_launcher_lease.dart`) reads the same
  `dev/runtime-launcher-<port>.json` family the launcher writes, so the
  supervisor and `sanad-dev` agree on who owns the runtime; a lease of another
  schema version is ignored rather than reinterpreted.
- The configured root and child path components are rejected when they are
  symlinks; the resulting real path is verified against the canonical root.
- Identity prepare creates `workspaces/` as a non-symlink managed remote
  workspace root. The daemon MUST refuse to start on a symlink or overlap home.
- Loopback is mandatory for any local binding; non-loopback is rejected
  with a single warning and non-zero exit (INV-1).

## Logging
- Never log the canonical home path, the file name, the secret bytes,
  the token, or any payload content.
- Boundary errors expose stable reason codes without including filesystem paths
  or payload content.

## Tests
- `agent/test/core/sanad_home/sanad_home_bootstrap_test.dart` — atomic
  write, `0600` re-assertion, `..`/symlink rejection, root preparation
  without recursive scans, overlapping roots, and SQLite sidecar permissions. Native
  Windows ACL execution remains platform-specific release evidence.
- `agent/test/core/sanad_home/loopback_policy_test.dart` — `0.0.0.0`
  rejection, `127.0.0.1` and `::1` acceptance, `localhost` acceptance,
  `192.168.x.x` rejection.
- `agent/test/core/sanad_home/installed_home_record_test.dart` — the
  install-record probe (artifact layout, absent record, symlinked record) and
  the ordered Home resolution (`--home`, `SANAD_HOME`, install record, account
  default), including the dedicated-account shape whose record Home is also the
  account's own `$HOME`.
