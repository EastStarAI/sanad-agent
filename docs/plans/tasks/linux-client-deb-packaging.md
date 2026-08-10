---
title: "Linux Client DEB Packaging"
description: "Produce an installable Ubuntu/Debian Sanad Client package with desktop integration and release verification."
status: "Implemented and locally verified; hosted release CI pending"
---

# Linux Client DEB Packaging

## Goal

Make the primary Linux x64 download a directly installable `.deb` while retaining the relocatable `tar.gz` for advanced users.

## Design

- Build the Flutter Linux bundle on the Ubuntu 22.04 compatibility baseline.
- Install application runtime files under `/opt/sanad-client`, expose `/usr/bin/sanad-client`, and install the existing desktop entry and hicolor icons under `/usr/share`.
- Publish both `.deb` and `tar.gz` in the release manifest; Production `/client/linux` resolves to the `.deb`.
- Linux user-initiated update discovery opens the canonical `.deb` artifact.
- Package tests inspect metadata/layout, launch an extracted package in isolation, and on CI perform real install, launch, and purge verification.

## Definition of Done

- The `.deb` builds deterministically from the release bundle and carries the release version and `amd64` architecture.
- Desktop launcher and all icon sizes are installed in standard system locations.
- The package installs, launches, and uninstalls on the Ubuntu 22.04 release runner without touching an existing Sanad Home.
- The release contract, Stable convenience redirect, update discovery, user guide, and QA matrix select the `.deb` as the primary Linux package.
- The legacy `tar.gz` remains published and passes its compatibility smoke test.

## Local verification

On Ubuntu 22.04 with GLib 2.72, the rebuilt portable bundle and `.deb` launched
successfully without the GLib 2.80-only symbol. The `.deb` passed deterministic
rebuild comparison, metadata and icon-layout inspection, an isolated `dpkg`
install/remove transaction, and a user-confirmed privileged install,
eight-second launch smoke, and purge through the `--install` mode of
`scripts/release/test_linux_deb_package.sh`.
