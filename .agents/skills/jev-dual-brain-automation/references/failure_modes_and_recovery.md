# Failure Modes and Recovery

## Principle

System 1 classifies evidence. It does not own causal recovery, phase history, or safety policy. Detect failure deterministically and escalate before another side effect.

## Failure taxonomy

### Low confidence or flat distribution

**Signal:** Choice/Score confidence or selected probability is below the phase threshold.

**Response:** Do not act. Gather better evidence, ask for confirmation, or escalate to System 2. Never silently choose the top option.

### Invalid or stale target

**Signal:** Jev returns an ID absent from the current observation, or the UI changed after classification.

**Response:** Reject the decision. Re-observe and reclassify only if the phase remains safely retryable.

### Layer or blocker blindness

**Signal:** A modal, consent prompt, captcha, permission card, error, or loading layer prevents the selected target from receiving the action.

**Response:** Stop the normal phase. Escalate the blocker evidence. Captchas and authorization prompts remain human/policy boundaries; do not bypass them.

### Repetition

**Signal:** The same target would be acted on three consecutive times.

**Response:** Trip before the third action and escalate the bounded history.

### Oscillation

**Signal:** Four prospective actions alternate between two targets, such as Search → Date picker → Search → Date picker.

**Response:** Trip before the fourth action. System 2 diagnoses the missing subtask or wrong page-mode classification.

### No transition

**Signal:** The post-action fingerprint equals the pre-action fingerprint, or no relevant transition event arrives before the deadline.

**Response:** Fail closed. Do not infer success from an action command's zero exit code.

### Irreversible phase ambiguity

**Signal:** Send, submit, delete, purchase, booking continuation, permission approval, or another externally visible action was attempted but confirmation is missing.

**Response:** Preserve the attempted phase and escalate. Never retry automatically; doing so can duplicate the side effect.

### Jagged task mismatch

**Signal:** The decision requires arithmetic, exact date selection, spatial reasoning, dependent planning, policy interpretation, or broad causal diagnosis.

**Response:** Keep exact operations in code and route structural reasoning to System 2. Jev may later resume narrow judgments after a fresh observation.

## Event-driven waiting

After an action, subscribe to the owning event stream and block for relevant transitions. Examples:

- browser navigation/load/DOM transition;
- Sanad response lifecycle or conversation event;
- dialog appearance/disappearance;
- exact keyed widget becoming present or absent.

Each event may be tested by deterministic predicates. This is not polling: no repeated snapshot or Jev request occurs while no event is emitted. Apply one deadline to the wait and escalate on timeout.

## System 2 handoff

Provide bounded, non-secret context:

```json
{
  "reason_code": "no_transition",
  "goal": "Send one exact test message",
  "phase": "send_message",
  "irreversible_attempted": true,
  "screen_mode": "conversation",
  "candidate_ids": ["send_message_btn"],
  "completed_phases": ["create_conversation", "enter_text"],
  "recent_actions": [
    {"phase": "send_message", "target": "send_message_btn"}
  ]
}
```

Do not include secrets, obscured field values, authentication URLs, or unrelated UI content.

After intervention:

1. Re-observe the UI.
2. Preserve completed and irreversible-attempted phases.
3. Rebuild current candidates.
4. Reclassify only the next safe, retryable decision.
5. Reapply confidence and policy gates.

Never “recover” by clearing all history; that re-enables duplicate side effects.
