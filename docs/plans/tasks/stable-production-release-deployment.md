---
title: "Stable Production Release Deployment Handoff"
description: "Connect approved Stable publication to Production Web, Appcast, and installer deployment without weakening protected release or rollback boundaries."
status: "in_review"
priority: "critical"
design_contract: "docs/operations/release_and_signing.md"
qa_contract: "docs/qa_maintenance/release_verification.md"
---

# Stable Production Release Deployment Handoff

## Problem

The Stable release workflow publishes an immutable Release and deploys the
Production-only Client aliases, but it does not invoke the prepared Production
asset workflow. The manual asset workflow references three Environment names
that do not own the existing restricted deployment credentials, so a manual
`v1.0.1` dispatch failed before connecting to the host.

## Goal

A successful, approved Stable publication automatically deploys Production Web,
Appcast, and canonical installer sources from the same tagged release run. The
handoff must retain the publication approval, immutable source identity, GitHub
attestation verification, atomic selector activation, Web rollback, and the
existing restricted deployment credential boundary. RC publication must never
deploy Production assets.

## Design

- Make `.github/workflows/deploy.yml` reusable while retaining its bounded manual
  recovery dispatch.
- Invoke it from `.github/workflows/release.yml` only for Stable, after the
  approved publication and Stable Client alias deployment succeed.
- Pass the current release run ID so the private attested Web handoff is fetched
  from the exact producing run.
- Use the existing `client-downloads-production` Environment for every
  Production asset job. It already owns the restricted SSH credential set and
  restricts normal release deployments to `v*` tags.
- Keep the manual recovery path fail-closed: a default-branch dispatch also
  requires an explicitly reviewed Environment branch-policy allowance before it
  can access deployment credentials.
- Add static CI assertions and update release/QA documentation so the automatic
  handoff and Environment ownership cannot silently drift apart.

## Definition of Done

- [x] `deploy.yml` supports `workflow_call` and `workflow_dispatch` with the same
      typed release identity and surface flags.
- [x] Stable publication calls the reusable deployment with Web, Appcast, and
      installers enabled and the exact producing run ID.
- [x] RC and validation-only runs cannot enter Production asset deployment.
- [x] Deployment jobs use `client-downloads-production`; obsolete empty
      Production asset Environment names are not referenced.
- [x] Existing Web attestation, immutable upload, public source verification,
      atomic activation, and bounded rollback remain intact.
- [x] Release workflow security checks assert the automatic handoff and shared
      protected Environment boundary.
- [x] Release architecture and QA documentation describe automatic Stable
      deployment and manual recovery prerequisites.
- [x] Focused workflow/static validation passes with bounded output.
- [x] Graphify is updated after the workflow/documentation change.

## Live activation follow-up

The first `v1.0.1` recovery run proved that changing a host selector does not
refresh an existing Docker bind mount. Web activation failed before selection
because the canonical root lacked a baseline, while Appcast and installer jobs
changed their new selectors without changing the publicly mounted legacy
content. The permanent handoff therefore also requires a bounded Production
static-container refresh after every selector change and rollback.

### Follow-up Definition of Done

- [x] Web activation refreshes only `app-site` after selecting or restoring a
      release.
- [x] Appcast activation captures the previous selector, refreshes only
      `updates-site`, verifies the exact public bytes, and rolls back on failure.
- [x] Installer activation captures the previous selector, refreshes only
      `downloads-site`, verifies both exact public source files, and rolls back
      on failure.
- [x] Every refresh uses the private host-owned `sanad-sites-control
      refresh-static production <surface>` command; the public workflow does not
      gain Docker or general host authority.
- [x] Manual and automatic Stable deployments share the same reusable workflow.
- [x] Focused workflow contracts, documentation checks, and Graphify update pass.
