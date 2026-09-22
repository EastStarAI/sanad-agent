# TypeSafe Jev API Specification & System 1 Reference

## Overview
TypeSafe Jev (`jev-latest`, `jev-1.13.0`) is a non-generative, sub-second decision engine designed for autonomous agent micro-loops. Instead of producing free-form tokens, it evaluates semantic candidates and probabilistic assertions directly from state descriptions.

- **Base Endpoint**: `https://api.typesafe.ai/v1/systemone`
- **Authentication**: `Authorization: Bearer <TYPESAFE_API_KEY>`
- **Cost**: Approximately **\$0.042 per 1M tokens** (~95% cheaper than typical frontier LLM calls).
- **Latency Profile**: **600ms – 1100ms** roundtrip per multi-question payload.

---

## Core Primitives

### 1. `choice`
Selects the single best option from a dictionary of candidate criteria based on the provided state context.

```json
{
  "state": "Goal: Log in to account\nCandidates:\n@e12: button 'Sign In'\n@e15: link 'Forgot Password'",
  "model": "jev-latest",
  "questions": {
    "next_click": {
      "type": "choice",
      "instructions": "Which element should be clicked to begin logging in?",
      "criteria": {
        "e12": "button 'Sign In'",
        "e15": "link 'Forgot Password'"
      }
    }
  }
}
```

**Response Format**:
```json
{
  "answers": {
    "next_click": {
      "choice": "e12"
    }
  }
}
```

---

### 2. `noul`
Returns a continuous probability value between `0.0` and `1.0` evaluating a boolean assertion against the state. Used for goal completion verification and modal detection.

```json
{
  "state": "Current Screen: Welcome dashboard with user avatar and recent documents list.",
  "model": "jev-latest",
  "questions": {
    "is_logged_in": {
      "type": "noul",
      "instructions": "Is the user currently authenticated and viewing their main dashboard?"
    }
  }
}
```

**Response Format**:
```json
{
  "answers": {
    "is_logged_in": {
      "noul": 0.94
    }
  }
}
```

---

### 3. `score`
Assigns relative normalized scores across candidate options for ranking priority actions or search results.

```json
{
  "state": "Search Query: flight from Cairo to Dubai",
  "model": "jev-latest",
  "questions": {
    "rank_destinations": {
      "type": "score",
      "instructions": "Score each destination based on relevance to Dubai",
      "criteria": {
        "opt1": "Dubai International Airport (DXB)",
        "opt2": "Doha Hamad International (DOH)",
        "opt3": "Abu Dhabi International (AUH)"
      }
    }
  }
}
```

---

## Best Practices for Prompting Jev

1. **Keep Candidate Descriptions Concise**: Truncate candidate labels to ~70 characters to maximize classification accuracy and keep prompt tokens minimal.
2. **Include Recent Action History**: Passing the last 2-3 executed actions in the `state` prevents Jev from repeating an action that just fired.
3. **Combine Verification and Choice in a Single Request**: Send both the `choice` question and the `noul` verification question in a single payload to eliminate redundant network roundtrips.
