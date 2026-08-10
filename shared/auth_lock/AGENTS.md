# Native Authentication Lock Contract

## Scope
This contract applies to `shared/auth_lock/`.

## Ownership
- Own only the native operating-system advisory lock that serializes shared Sanad authentication mutations across processes.
- The stable lock file is `auth.refresh.lock` under the active Sanad Home. Never replace or delete it during normal operation.
- The lock contains no credentials and must never transport or expose authentication state.
- Callers own `auth.json`, Portal requests, token interpretation, and credential-free exchange notifications.

## Platform Boundary
- The package supports native Dart runtimes on Windows, Linux, and macOS.
- Web and mobile authentication flows must not invoke this lock.
- Use non-blocking lock attempts with a bounded retry loop; do not leave an uncancellable blocking lock future behind after timeout.
