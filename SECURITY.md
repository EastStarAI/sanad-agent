# Security Policy

## Reporting a Vulnerability

Do not report vulnerabilities through public issues, pull requests, discussions, logs, or community chat.

Use the repository's private **Report a vulnerability** form, backed by GitHub Private Vulnerability Reporting. This channel must be enabled before the repository becomes public. If that form is unavailable, email `security@eaststarai.com`. Include the affected revision or version, platform, impact, reproduction steps, and any suggested mitigation. Remove access tokens, user content, personal paths, and other sensitive data from the report.

The maintainer will acknowledge and assess reports on a best-effort basis. As a solo-maintained project, Sanad Agent does not promise a fixed response SLA. Coordinated disclosure timing is agreed privately after impact and remediation are understood.

## Supported Versions

Security fixes target the latest supported release line. When multiple release lines are supported, this section lists them explicitly; otherwise users should update to the latest published version before reporting an already-fixed issue.

## Scope

This policy covers the open-source Dart agent, Flutter client, public scripts, release tooling, and public documentation. Vulnerabilities in EastStar AI hosted services should use the same private reporting entry point and identify the affected hosted domain without including live credentials.

Third-party model providers, MCP servers, operating systems, and package dependencies remain subject to their own security policies, but unsafe integration behavior in Sanad Agent is in scope.

## Security Expectations

- Secrets and user tokens remain outside Git and are redacted from diagnostics.
- Tool execution remains constrained by workspace policy, user approval, and operating-system permissions.
- Release downloads must not be treated as trusted until the release task publishes signatures or checksums and documents verification.
- Fork pull requests do not receive signing or deployment secrets.

<!-- Temporary SANAD-11 fork CI probe; not for merge. -->
