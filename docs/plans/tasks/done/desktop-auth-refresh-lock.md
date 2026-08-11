# Desktop Cross-Process Authentication Lock

## Problem

The native Flutter client, Dart daemon, and CLI share `SANAD_HOME/auth.json`. A socket reconnect can make the client and daemon submit the same rotating refresh credential concurrently. The backend correctly treats the second use as replay and revokes the entire refresh family.

Atomic replacement protects readers from partial JSON, but it does not serialize the read-refresh-write transaction or prevent lost updates between processes.

## Design

1. Add one shared pure-Dart cross-process lock implementation used by both the agent and client.
2. Use a stable owner-only `auth.refresh.lock` file under the active Sanad Home. Acquire an operating-system advisory exclusive lock through `RandomAccessFile.lock`, which maps to native file locking on Windows, Linux, and macOS. Never replace or delete the lock file during normal operation.
3. On native desktop refresh, acquire the lock before reading the credential, then re-read `auth.json`:
   - if another process already persisted a different access/refresh pair, adopt it and do not call the Portal;
   - otherwise perform the bounded Portal refresh while holding the lock, atomically persist the complete rotated pair, then release the lock.
4. Serialize native desktop login, logout, pairing, and auth-document read-modify-write mutations through the same lock so they cannot overwrite a concurrent rotation.
5. Keep `authentication_exchange` credential-free. It remains only a local authenticated reload notification; no bearer or refresh credential crosses the Local Gateway.
6. Web and mobile retain their existing in-process refresh behavior and never open `auth.json` or the desktop lock.
7. Preserve backend refresh-token replay detection unchanged.

## Failure Boundaries

- Operating-system locks are released when a process exits, avoiding stale sentinel locks.
- Lock acquisition and Portal refresh are bounded by explicit timeouts; timeout/transport failures preserve credentials.
- A process crash after the Portal consumes a refresh credential but before local persistence remains an inherent rotating-token commit gap and is outside the simultaneous-process race fixed here. Eliminating that gap would require a separate server-side idempotent refresh protocol.

## Verification / Definition of Done

- Shared lock tests prove exclusive serialization and release after exceptions.
- Agent tests prove a waiter adopts a pair rotated by another lock holder without a second refresh request.
- Client tests prove the same desktop behavior and preserve non-desktop behavior.
- Existing credential-free authentication exchange tests remain green.
- `fvm dart analyze` and focused agent tests pass.
- `fvm flutter analyze` and focused client tests pass.
- Documentation describes the lock, platform boundary, and remaining crash gap.
