---
id: 101
title: Client Appearance Customization (Background, Theme, Font, and Scaling)
status: completed
gate: G8
created: 2026-09-23
completed: 2026-09-23
branch: feature/95-client-multilanguage
---

# Task 101 — Client Appearance Customization & Agent Visual Identity

## Goal
Empower users to personalize the Sanad desktop client appearance through settings by providing four color themes (Light, Dark, Midnight, Sepia), 8 curated primary colors, font family selection (featuring Cairo for Arabic, alongside Inter, Roboto, and System Default), font size scaling (Small, Normal, Large, Extra Large), and six background options (Default, two solid colors, and three nature wallpapers) equipped with an adaptive semi-transparent overlay.

Furthermore, anchor the visual identity to the connected Agent: appearance preferences are stored and owned by the agent itself in `SANAD_HOME/appearance.json`. When switching between devices/agents in the client, each agent's unique appearance profile is automatically applied. The protocol provides transport-neutral `get_appearance` and `update_appearance` handlers via `SanadProtocolBridge` (serving both local and cloud platforms), piggybacking appearance in `loadSanadCapabilities()` for zero-extra-roundtrip handshakes, with instant local cache fallback and JSON export/import capabilities.

## Locked Decisions & Scope
- **Phase 1 (Completed):**
  - 4 theme styles: `light`, `dark`, `midnight`, `sepia`.
  - 8 primary/accent colors in 2 rows of 4: Blue (default), Teal, Green, Cyan, Purple, Magenta, Orange, Rose.
  - Transparent/frosted glass styling across settings, MCP, and provider screens.
  - Symmetrical 30px padding and reordered general settings (Updates -> Languages -> Appearance -> Background).
- **Phase 2 — Agent-Owned Appearance & Multi-Agent Visual Identity (Active):**
  - **Storage:** Persisted on the Agent side in `SANAD_HOME/appearance.json`.
  - **Protocol & Transport Neutrality:**
    - Handled via `SanadProtocolBridge` using `AppearanceCommandHandler`, serving both `LocalDaemonServerPlatform` (Local Loopback) and `ServerSanadGatewayPlatform` (Cloud Gateway).
    - `loadSanadCapabilities()` includes the current `appearance` payload top-level to achieve zero extra round-trips upon initial connect or device inventory refresh.
    - Independent commands `get_appearance` and `update_appearance` for isolated query and lightweight updates without fetching full capabilities.
  - **Multi-Device / Agent Switching:**
    - Each device config has its own visual profile. Switching `activeAgent` in `DeviceCubit` triggers `AppearanceCubit` to switch to that device's appearance.
    - Device-scoped client caching (`appearance_<device_id>`) for instant zero-flicker transitions.
    - Graceful fallback: If an agent lacks appearance data or is offline, defaults (`AppearanceState.initial()`) are applied safely.
  - **Export & Import:**
    - Export button in Settings saves the current agent's appearance profile to a `.json` file using `file_selector`.
    - Import button allows selecting a JSON file, validates the schema, applies it immediately to the client, and commits it to the active agent.

## Gates

### G0–G5 (Phase 1 — Completed)
- [x] G0 — Discovery & Design Audit.
- [x] G1 — Data Layer & Persistence (Initial Client Cubit).
- [x] G2 — Themes & Typography Engine.
- [x] G3 — Background Wallpaper & Adaptive Scrim Layer.
- [x] G4 — Settings Appearance UI & Localization (8 colors, reordered cards).
- [x] G5 — Verification & Live Testing.

### G6 — Agent Appearance Storage & Protocol Handler (Completed)
- [x] Create `AppearanceStore` / `appearance_store.dart` in `agent/lib/core/appearance/` to read/write `appearance.json` within `SANAD_HOME`.
- [x] Implement `AppearanceCommandHandler` in `agent/lib/interfaces/platforms/sanad_gateway/handlers/appearance_command_handler.dart`.
- [x] Wire `AppearanceCommandHandler` into `SanadProtocolBridge` for commands `get_appearance` and `update_appearance`.
- [x] Include appearance metadata in `loadSanadCapabilities()` in `capabilities_loader.dart` and `AgentCapabilities`.
- [x] Write unit tests for agent appearance store, command handler, and bridge routing (`agent/test/`).

### G7 — Client Multi-Agent Switching & Sync (Completed)
- [x] Update `AppearanceCubit` to support per-device caching and synchronization with active agent.
- [x] Listen to `DeviceCubit` for active agent switches and load the corresponding appearance profile with fallback to defaults.
- [x] Dispatch `update_appearance` to the active agent upon settings modification.
- [x] Write unit tests for client device-scoped appearance switching and fallback.

### G8 — Export & Import Features & Localization (Completed)
- [x] Add Export and Import actions to Appearance Card in `GeneralPage` using `file_selector`.
- [x] Implement JSON validation, error handling, and toast feedback for import/export.
- [x] Add localization keys in `app_en.arb` and `app_ar.arb`.
- [x] Verify `fvm flutter analyze` and targeted tests.

## Definition of Done
- [x] Static analysis passes with 0 issues in both `agent/` and `client/`.
- [x] All unit and integration tests pass (27/27 tests).
- [x] Appearance persists in `SANAD_HOME/appearance.json` on the agent.
- [x] Switching devices in the client switches appearance immediately.
- [x] Export and import produce and consume valid JSON appearance configurations.

## Current Status
- Gate: G8 (Completed)
- All automated tests, static analysis, and multi-agent appearance syncing verified.
