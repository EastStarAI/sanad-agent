---
title: "MCP Server Configuration QA"
description: "Security, form, import/export, OAuth, lifecycle, and regression checks for daemon-owned MCP server configuration."
---

# MCP Server Configuration QA

## Authority and security

- Device and Workspace management commands succeed only through the authenticated local gateway; every import, export, Advanced JSON, inspection, and OAuth command remains rejected on the cloud management path.
- Device and Workspace snapshots preserve same-name Workspace precedence and contain configured markers only, never bearer, header, environment, OAuth access/refresh, or client-secret values.
- Draft inspection uses entered credentials ephemerally and leaves neither configuration nor secret-store files behind.
- Export and Advanced initial JSON omit every credential shape. Errors and OAuth status snapshots do not echo response bodies or tokens.

## Form and cards

- The management destination has server cards and no permanent JSON pane. Its embedded Device/Workspace Settings presentation keeps a visible `Add server` action inside the page content rather than relying on a hidden route AppBar. Cards distinguish Enabled, connection health, authentication, transport, tools, and origin.
- Add and Edit share Remote and Local branches. Remote covers Auto/HTTP/SSE plus None/Bearer/OAuth/Custom Headers. Local covers command, structured arguments with paste parsing, and structured environment rows.
- Configured secrets display `Configured` with explicit Replace/Remove; stored values never populate a field.
- Test performs daemon inspection, then review presents detected transport and selectable tools before Save.
- Compact widths keep key/value rows usable, actions wrap, and the fixed footer remains reachable by keyboard.

## Import, export, and Advanced JSON

- Import accepts wrapped, bare-map, and named-single-server shapes; preview reports aliases, warnings, and unsupported fields before seeding the same typed form.
- Duplicate normalized names, command/URL contradictions, inline credential shapes, malformed JSON, and input over 256 KiB fail without mutation.
- Export copies redacted ecosystem JSON and explicitly confirms credentials were excluded.
- Advanced JSON opens for one selected server, requires successful preview, displays changed fields, rejects another server/root document, and rejects stale base or preview revisions.

## OAuth lifecycle

- Discovery accepts explicit metadata or standards-based protected-resource/authorization-server metadata; missing endpoints and registration failures end with redacted actionable errors.
- Authorization uses an opaque flow ID, loopback callback, random state, and S256 PKCE. Client snapshots expose only status, authorization URL, expiry, and redacted error.
- Approval validates state and exchanges the code; access/refresh/client-secret values move directly into daemon secret storage before normal runtime inspection.
- Cancellation and expiry close callback resources. Wrong state, denied authorization, failed exchange, and late callbacks are terminal and cannot persist partial configuration.
- Retrying starts a fresh flow. Closing the browser leaves the bounded flow pending until cancellation or expiry; it never creates an unbounded poll or listener.

## Automated verification

- Agent: MCP configuration/secret/import/Advanced tests, runtime inspection tests, OAuth lifecycle tests, local protocol tests, and remote-management rejection tests.
- Client: typed runtime-client tests; form branch/configured-secret/import widget tests; and management-card Export, Advanced preview/save, tool-selection, origin/precedence, compact-width, and semantics tests.
- Management accessibility assertions cover a named expandable card, an independently named/toggled server control, and named/toggled tool controls; compact verification uses a 320 px logical width and fails on any layout exception.
- Advanced JSON tests must close through the real dialog animation so controller ownership and post-close reload cannot regress into use-after-dispose failures.
- Run both analyzers. Run the daemon-backed local MCP protocol E2E with isolated temporary state and `--concurrency=1`. Migration and OAuth loopback use bounded real filesystem/HTTP fixtures in agent tests; do not add or run external STDIO/OAuth fixtures unless they are deterministic, secret-free, and prove a boundary not already covered.
