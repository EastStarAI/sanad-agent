---
title: "README Client Downloads"
description: "Limited English/Arabic Quick Start refresh using the Production-only stable Client convenience links."
---

# README Client Downloads

## Status

Complete.

## Goal

Simplify only the end-user Quick Start in the English and Arabic READMEs so users download Sanad Client directly without navigating the mixed GitHub Release asset list.

## Contract

- Keep the overall README structure and technical content unchanged.
- Present direct Production-only convenience links for macOS, Windows, and Linux.
- After each approved Stable publication, verify the public manifest, checksums, artifact sizes, hashes, and attestations before generating and deploying the three redirect destinations through the protected `client-downloads-production` Environment.
- Keep GitHub Releases as the artifact origin; the private server returns redirects and never mirrors or proxies Client bytes.
- Explain that Run Locally manages the matching Agent; users do not download Agent separately.
- Keep Android and iOS out of the native download buttons until stable distribution is approved.
- Preserve a concise Windows unsigned-build warning and link to the full user guide.
- Keep English and Arabic flows equivalent.

## Definition of Done

- Both READMEs expose the same three platform actions in the same order.
- Every action uses `https://downloads.sanad.eaststarai.com/client/<platform>`.
- No Quick Start action sends an end user to the mixed GitHub Release page.
- Documentation link and static parity checks pass.
