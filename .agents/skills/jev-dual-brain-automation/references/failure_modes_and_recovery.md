# System 1 Failure Modes, Circuit Breakers, and Escalation Patterns

## The Nature of System 1 Blindspots
TypeSafe Jev operates as a pure semantic and perceptual classifier. It maps semantic descriptions to goal-oriented choices with high speed and zero generative latency. However, because it lacks causal multi-step reasoning and deep world models, it exhibits predictable failure modes when operating alone:

1. **Overlay Blindness (Layer Invisibility)**:
   - *Symptom*: When a cookie banner, modal backdrop, or alert dialog covers the screen, Jev continues selecting the underlying target button (e.g. "Destination" or "Search") because its label matches the goal, unaware that clicks are intercepted by the overlay.
2. **Ping-Pong Oscillation**:
   - *Symptom*: The agent clicks "Search", a date picker opens; Jev clicks "Departure", the calendar expands; Jev clicks "Search" again without selecting calendar cells. The agent enters an infinite loop between 2 or 3 elements.
3. **Multi-Dimensional Spatial Matrices**:
   - *Symptom*: Interactive calendar grids, complex sliders, canvas drawing tools, and drag-and-drop elements cannot be resolved by simple 1-of-N discrete choices.

---

## Defensive Strategy: The Three Pillars

### Pillar 1: Pre-Flight Prevention via Persistent Profile
Prevent transient cookie banners, consent prompts, and session resets by launching `agent-browser` with a persistent profile directory:

```bash
agent-browser --headed --profile ~/.sanad/browser-profile open "https://example.com"
```
Once cookies are accepted or credentials saved in the profile, subsequent runs remain free of overlay interruptions.

---

### Pillar 2: The Circuit Breaker Pattern
The runner tracks executed actions in an `action_history` buffer. After each step, a deterministic rule checks for repetitive loops:

- **Single-Element Lock**: If the same element ID is targeted 3 times consecutively.
- **Oscillating Loop**: If the last 4 actions alternate between a set of <= 2 element IDs.
- **No-DOM-Change Lock**: If the snapshot hash does not change after an executed action.

When any condition is met, the **Circuit Breaker immediately trips**, pauses the Jev micro-loop, and emits an escalation event with full execution context.

---

### Pillar 3: System 2 Handshake Protocol
System 2 (Frontier LLM / High-Level Orchestrator) intervenes only when the Circuit Breaker trips:

1. **Ingest Context**: System 2 receives:
   - Reason for trip (e.g., `Oscillation between Search and Date Picker`).
   - Current raw DOM snapshot or semantic tree.
   - Action history buffer.
2. **Diagnose & Solve Structural Blocker**:
   - Dismiss the modal, accept the terms, solve the captcha, or select the specific calendar cells.
3. **Clear History & Re-delegate**:
   - Flush the `action_history` buffer.
   - Hand control back to the System 1 Jev micro-loop to resume fast sub-second execution.
