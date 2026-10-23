# Decision-layer fixtures

`snapshots/` holds 24 captured keyed-widget dumps of the Sanad Client, and
`labels.json` records, for each snapshot, the screen mode it must classify as and
the candidate ids that are correct for one stated task.

They are the offline half of the Jev P0 evidence: they let the decision layer's
extractor, mode classifier, guard, and model interface be tested without a
runtime, a Client, or a model call.

## Provenance

The dumps were captured with `sanad-dev ui snapshot --interactive --compact
--json` against a throwaway Test Home during the P0 decision replay, which spent
two model calls to render an `ask_user` card and a permission card. Each file is
one snapshot: `{status, count, generation, signature, fresh, elements[]}` where an
element is `{type, key, text, hint, tooltip, semantics_label, selected, button,
enabled}`.

Coverage: conversation idle, streaming, post-`ask_user`, post-deny, and empty
session; conversation search open and with results; model picker plain and
filtered; the composer permission-mode, thinking-mode, and device-switcher
popups; an `ask_user` card in three states (options, custom answer, second
question); a permission card in two states (options, deny comment); and settings
for general, MCP servers, skills, providers, device, workspace, and profile.

## Sanitization

Fixtures are the only captured UI state that enters the repository, so they were
scrubbed before import:

| Risk | Handling |
| --- | --- |
| Absolute filesystem paths (`/Users/...`, `/Volumes/...`, `/etc/...`) | replaced with `<path>` |
| Secret-shaped strings (`sk-`, `AIza`, `ghp_`, `Bearer`) | replaced with `<redacted>` |
| Entered text in a text field | never emitted by the extractor; only `[empty]` or `[filled]` |
| Email addresses, account ids, tokens | none present; `tests/test_decision_layer_fixtures.py` fails the build if one appears |

Conversation titles, workspace names, and model ids are retained: they are
generated test content and they are what makes the fixtures usable as decision
evidence.

## Labels

Each entry in `labels.json` declares:

| Field | Meaning |
| --- | --- |
| `mode`, `mode_detail` | the classification the fixture must produce, recorded as a golden expectation |
| `phase`, `task` | the scenario step and the natural-language goal given to the model |
| `correct` | candidate ids accepted as right for that task, or `abstain` |
| `trap` | an adjacent control looks right and is wrong |
| `irreversible` | the scenario has a security-relevant or externally visible effect |
| `action_irreversible` | whether the accepted id is irreversible under the action table |
| `guard_enforced` | no action is correct here: the layer must refuse, never admit |

`12-settings-device.json` supersedes its B10 label. B10 recorded `abstain`
because the screen-agnostic 32-candidate cap removed `device_restart_agent_button`;
mode-scoped tables restored the control, so the honest label is the control
itself.

## Adding a fixture

1. Capture one `sanad-dev ui snapshot --interactive --compact --json` on the
   screen a scenario needs, and confirm no personal data or secret is in it.
2. Add it here and add a `labels.json` entry with its expected mode and the
   correct candidate ids.
3. If the screen needs a control the action table does not declare, add the rule
   in `../../scripts/decision_layer/actions.py` first; an undeclared control is
   invisible to the layer by design.
