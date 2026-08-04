# Public Client Endpoint Configuration

## Ownership boundary

The public Flutter client owns the Production service endpoints and the
loopback endpoints used by the explicit local profile. It does not own the
hostnames of privately operated Development or Staging environments.

`ENVIRONMENT` selects application behavior and diagnostics. It is not a
directory of private infrastructure. Consequently, every non-local public
profile defaults to the Production Backend and Portal unless the build owner
provides explicit compile-time overrides.

## Build-time inputs

The supported hosted-service inputs are:

| Input | Purpose | Public fallback |
|---|---|---|
| `ENVIRONMENT` | Identifies application behavior as `dev`, `stg`, or `prod` | `prod` |
| `BACKEND_URL` | REST and Socket.IO cloud gateway origin | Production Backend |
| `PORTAL_URL` | Authentication Portal origin | Production Portal |

`LOCAL_GATEWAY_URL` is a separate desktop-only daemon boundary. It is not the
hosted Backend address and must not be used to configure a Flutter Web build.

Private deployment automation owns any Development or Staging values and
injects both hosted URLs explicitly while building the pinned public commit.
Those values do not belong in the tracked public JSON profiles, endpoint
constants, or public deployment workflows.

## Failure-safe behavior

A missing private override cannot silently select another private environment.
Development, Staging, unknown, and Production profile names all use Production
hosted endpoints by default. Only the explicit `local` profile selects the
tracked loopback Backend and Portal.

This fallback prevents a public source build from depending on private
infrastructure while preserving reproducible Production and local builds.
