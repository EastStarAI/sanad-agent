---
title: "Complete sanad-dev Interactive Terminal Controls"
description: "Forward the complete Flutter command set, add safe Agent stop keys, and keep the Client log sidecar bounded and alive during cold builds."
---

# Complete sanad-dev Interactive Terminal Controls

## Problem

The managed Client terminal forwards only Flutter `r` and `R`, the Agent terminal has no direct safe-stop key, and the automatically opened Client log sidecar replays all retained history. Its startup grace also remains limited to 100 seconds, so it can return to the shell while a valid cold build continues under the newer five-minute Client startup window.

## Change

- Forward Flutter `r`, `R`, `h`, `d`, `c`, and `q` through the owning launcher.
- Interpret Agent `s` and `q` as the existing resumable managed Agent stop operation.
- Open automatic Client terminals with only the latest 50 retained lines.
- Keep the Client log sidecar alive through the complete managed startup/control window.
- Update focused protocol, terminal-launcher, documentation, and QA coverage.

## Definition of done

- Every documented Flutter interactive key reaches the exact launcher-owned Client process.
- Agent `s` and `q` use checkpoint-safe shutdown and do not stop sibling Clients.
- Automatically opened Client terminals show at most 50 retained lines unless the user explicitly invokes `sanad-dev logs` with another history selection.
- A slow Client build does not close its log terminal before the five-minute startup decision completes.
- Static analysis and focused `sanad-dev` tests pass.
