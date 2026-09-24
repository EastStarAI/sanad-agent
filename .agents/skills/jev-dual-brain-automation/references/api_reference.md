# TypeSafe System One API Reference

Source basis: TypeSafe documentation for State, Primitives, Choice, Score, Noul, Confidence, confidence-gated routing, and Jev model jaggedness, reviewed 2026-09-22.

## Endpoint and authentication

- Endpoint: `POST https://api.typesafe.ai/v1/systemone`
- Header: `Authorization: Bearer <TYPESAFE_API_KEY>`
- Never track, print, or include the key in state, exceptions, eval fixtures, or command output.

## Request

```json
{
  "state": {
    "goal": "Open Skills settings",
    "phase": "choose_navigation_target",
    "screen_mode": "settings_navigation",
    "candidates": {
      "nav_tile_skills": "Skills",
      "nav_tile_mcp": "MCP Servers"
    }
  },
  "model": "jev-latest",
  "questions": {
    "target": {
      "type": "choice",
      "instructions": "Which candidate directly opens Skills?",
      "criteria": {
        "nav_tile_skills": "Directly opens Skills",
        "nav_tile_mcp": "Opens MCP instead"
      }
    },
    "blocked": {
      "type": "noul",
      "instructions": "Is a blocker preventing safe interaction?"
    }
  }
}
```

`state` may be a string, object, or array of text-bearing JSON values. Prefer an object with named relationships. Every question in one request sees the same state and is evaluated independently.

## Primitives and answers

### Choice

Use for one option from an unordered fixed set.

```json
{
  "choice": "nav_tile_skills",
  "probabilities": {
    "nav_tile_skills": 0.99,
    "nav_tile_mcp": 0.01
  },
  "confidence": 0.98
}
```

Retain all three fields. Validate that `choice` belongs to the current candidate map, then gate on a measured confidence threshold. Optionally inspect the selected option's probability or the full distribution.

### Score

Use for an ordered spectrum. Criteria are an ordered array with positions starting at zero. The returned score may fall between levels.

```json
{
  "score": 1.4,
  "legend": ["low", "medium", "high"],
  "probabilities": [0.1, 0.4, 0.5],
  "confidence": 0.72
}
```

Retain `score`, `legend`, `probabilities`, and `confidence`. Do not reinterpret Score as ranking independent candidates.

### Noul

Use for one yes/no proposition. The value is the probability of yes from 0 to 1. Noul has no separate confidence field.

```json
{
  "noul": 0.09
}
```

Optional criteria may define the true and false meanings:

```json
{
  "type": "noul",
  "instructions": "Is the workflow blocked?",
  "criteria": {
    "true": "A modal, captcha, permission, error, or unknown state blocks progress",
    "false": "The expected target is visible and safely actionable"
  }
}
```

## Independence and hierarchy

Batched questions reduce round trips only when they are independent judgments over the same state. The model does not evaluate question B conditional on its answer to question A.

Bad batch:

- `page_mode`: choose search, calendar, results, or booking summary.
- `next_action`: choose from actions that are valid only for whichever `page_mode` wins.

Correct sequence:

1. Ask for `page_mode`.
2. Code validates confidence and selects the candidate set for that mode.
3. Ask a second request for `next_action` among that set.

Independent `blocked`, `goal_complete`, and `target` judgments may share a request when each can be answered directly from the same state and code resolves conflicts conservatively.

## Confidence routing

Choice and Score confidence summarizes the shape of their probability distribution. Low confidence is useful uncertainty, not permission to act on the top option.

- Establish thresholds with representative evals.
- Raise thresholds with action consequence.
- Route medium confidence to confirmation, more evidence, or System 2.
- Route low confidence to no action.
- Keep probabilities in diagnostics so threshold failures remain explainable.

## Jev jaggedness

Jev is optimized for fast semantic judgments, not general reasoning. Keep these in deterministic code or System 2:

- phase ordering and state transitions;
- exact dates, arithmetic, prices, counts, and sorting;
- selector validity and action mechanics;
- retry and irreversible-action policy;
- dependent multi-step planning;
- unknown or structurally complex UI recovery.
