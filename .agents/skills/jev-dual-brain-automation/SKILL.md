---
name: jev-dual-brain-automation
description: Accelerate multi-step browser and desktop UI automation using the Dual-Brain architecture (TypeSafe Jev System 1 micro-loop + Strong Model System 2 escalation). Use whenever building high-speed browser automation with agent-browser, driving or testing Flutter desktop UI with sanad-dev ui, automating repetitive forms, web scraping, or testing interactive UI flows where low latency (~700ms), sub-cent cost ($0.042/M tokens), and resilient loop detection (circuit breaking) are required. Make sure to trigger this skill whenever high-speed browser interaction or automated UI testing is requested, even if the user does not explicitly mention Jev.
---

# Dual-Brain UI Automation (System 1 Jev + System 2 Escalation)

## 1. Overview & Architecture

Autonomous UI automation on modern web pages and desktop applications presents two competing requirements:
- **Speed and Cost**: Standard frontier LLMs introduce 3–8 seconds of latency and substantial token cost per discrete click or keystroke.
- **Robustness and Reasoning**: Pure lightweight classifiers fail when encountering unexpected overlays, multi-step date pickers, or circular UI loops.

The **Dual-Brain Architecture** solves this by establishing a clear division of labor:

```
┌────────────────────────────────────────────────────────┐
│               System 2: Frontier LLM                   │
│  - High-level Goal Decomposition                       │
│  - Obstacle Resolution (Captchas, Banners, Calendars)  │
│  - Resets Circuit Breaker & Re-delegates               │
└───────────────────────────▲────────────────────────────┘
                            │ Escalation Handshake
                            │ (When Circuit Breaker Trips)
┌───────────────────────────▼────────────────────────────┐
│               System 1: TypeSafe Jev                   │
│  - Sub-second DOM Candidate Selection (~700ms)         │
│  - Probabilistic Goal Verification (noul)              │
│  - $0.042 / 1M Tokens (High Frequency Micro-Loop)      │
└───────────────────────────▲────────────────────────────┘
                            │ Direct Execution
┌───────────────────────────▼────────────────────────────┐
│             Execution Interfaces                       │
│  - Web: agent-browser (Playwright / Chromium)          │
│  - Desktop: sanad-dev ui (Flutter VM Service Tree)     │
└────────────────────────────────────────────────────────┘
```

---

## 2. Environment & Key Management

Never hardcode or log API keys. Always retrieve `TYPESAFE_API_KEY` from local environment variables or private `.env` files.

### Setup Checklist
1. Ensure `TYPESAFE_API_KEY` is configured in `.env` (or `temp/.env`).
2. Verify Python virtual environment is active:
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   ```
3. Verify CLI tools are accessible:
   - For Web: `agent-browser --version`
   - For Desktop: `sanad-dev status`

---

## 3. Web Automation Workflow (`agent-browser`)

### Step 1: Pre-Flight Isolation with Persistent Profile
Always use a persistent profile to retain cookies, session tokens, and dismissed banners across sessions:

```bash
agent-browser --headed --profile ~/.sanad/browser-profile open "https://target-site.com"
```

### Step 2: DOM Ingestion & Candidate Pruning
Extract interactive elements using snapshot references (`@e1`, `@e2`):

```bash
agent-browser snapshot -i
```
Prune descriptions to ~70 characters before feeding into Jev to preserve context tokens and maximize classification accuracy.

### Step 3: Run the Jev Micro-Loop
Use the bundled runner [scripts/dual_brain_browser.py](scripts/dual_brain_browser.py) or invoke `jev_client.py`:

```python
from scripts.dual_brain_browser import DualBrainBrowser

def handle_system_2(reason, snapshot, context):
    print(f"🧠 Escalating to System 2: {reason}")
    # Inspect raw DOM, dismiss overlay, or select complex matrix element
    return True

browser = DualBrainBrowser(
    profile_dir="~/.sanad/browser-profile",
    headed=True,
    system_2_handler=handle_system_2
)

browser.execute_goal(
    goal="Search and filter data on the portal",
    start_url="https://portal.example.com",
    max_steps=12
)
```

---

## 4. Desktop UI Automation Workflow (`sanad-dev ui`)

Automating the Sanad Flutter desktop application leverages semantic accessibility trees rather than raw coordinate clicking.

### Step 1: Query the Semantic Widget Tree
```bash
sanad-dev ui tree
```
Extract active widget IDs and semantic labels (`[label="..."]`, `id=...`).

### Step 2: Formulate the State & Prompt Jev
Feed candidate widgets to Jev to select the target widget:

```python
from scripts.jev_client import JevClient

jev = JevClient()
target_widget, latency = jev.classify_choice(
    state="Goal: Enable dark mode\nCandidates:\nopt_theme: ListTile 'Dark Theme'\nopt_notif: ListTile 'Notifications'",
    instruction="Which widget should be tapped to toggle dark mode?",
    criteria={"opt_theme": "ListTile 'Dark Theme'", "opt_notif": "ListTile 'Notifications'"}
)
```

### Step 3: Dispatch Flutter Actions
```bash
sanad-dev ui tap opt_theme
```
Verify state transition using Jev's `noul` primitive:
```python
is_applied, _ = jev.evaluate_noul(
    state="Current settings tree with Dark Theme toggle checked",
    instruction="Is dark theme currently active in the settings?"
)
```

---

## 5. Circuit Breaker & Loop Detection Protocol

System 1 cannot reason about its own failures. Therefore, every runner must implement an automated **Circuit Breaker**:

1. **Oscillation Rule**: If the last 4 actions oscillate between $\le 2$ elements (e.g., clicking Search $\rightarrow$ Date Picker $\rightarrow$ Search $\rightarrow$ Date Picker), trip the breaker immediately.
2. **Repetition Rule**: If the same element is targeted 3 times consecutively with no state progression, trip the breaker immediately.
3. **Escalation Handshake**:
   - Pause the Jev micro-loop.
   - Hand the failure reason and raw snapshot to System 2 (the frontier model).
   - System 2 clears the blocker (e.g., picks required calendar cells, accepts terms dialog).
   - Clear the `action_history` buffer and re-delegate back to Jev.

---

## 6. Bundled Resources

- **[scripts/jev_client.py](scripts/jev_client.py)**: Standalone Python client for `choice`, `noul`, and `score` primitives.
- **[scripts/dual_brain_browser.py](scripts/dual_brain_browser.py)**: Turnkey web automation runner with circuit breaker and System 2 hooks.
- **[scripts/dual_brain_sanad_ui.py](scripts/dual_brain_sanad_ui.py)**: Flutter desktop automation runner via `sanad-dev ui`.
- **[references/api_reference.md](references/api_reference.md)**: Endpoints, pricing, payload formats, and prompting patterns.
- **[references/failure_modes_and_recovery.md](references/failure_modes_and_recovery.md)**: Deep dive into System 1 blindspots, overlay handling, and recovery patterns.
