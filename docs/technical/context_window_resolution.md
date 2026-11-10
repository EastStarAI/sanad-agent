# Context Window Resolution and the Global Cap

This page owns how one model's context window is decided in Sanad Agent: the
precedence between the user, the shipped defaults, and provider metadata; the
global cap; the fallback for a window nothing knows; and the provenance the
diagnostic surface reports.

Owner: `agent/lib/core/config/context_window_policy.dart` (the algorithm and
constants), `agent/lib/core/config/model_aware_runtime_policy.dart` (the parsed
`config.yaml` policy and its single resolver entry point), and
`agent/lib/core/provider_runtime/local_provider_routes.dart` (what counts as a
local/self-hosted route). Adapters do not own precedence.

## The decision

For each model, in this order:

| Order | Layer | Capped? |
| --- | --- | --- |
| 1 | User `context.modelLimits[<model>]` from `$SANAD_HOME/config.yaml` | **No**, applied as written |
| 2 | Shipped per-model default (see the table below) | Yes |
| 3 | Provider evidence: revision-matched instance catalog, live probe (LM Studio, llama.cpp, Ollama `/api/show`), `models.dev`, known static metadata | Yes |
| 4 | Nothing known | Cloud route: the cap. Local/self-hosted route: the local fallback, also capped |

The cap is `context.maxLimit` when the user set it, otherwise the shipped
`358000`. `context.maxLimit: 0` disables the cap; the resolved window is then the
uncapped layer value, and a cloud model with no evidence at all keeps the
adapter's pre-existing conservative fallback (4000 for OpenAI-compatible and
Ollama, 200000 for Anthropic Messages, the bounded estimate in the compaction
factory, 128000 in the compaction/recovery orchestrators).

Shipped per-model defaults are keyed by the normalized model id and **also match
the segment after the last `/`**, so `deepseek/deepseek-v4.1-flash` shares the
`deepseek-v4.1-flash` default. User-written keys stay an exact normalized match.

## Shipped defaults

| Model id | Window | Reason | Adopted |
| --- | --- | --- | --- |
| `gpt-6.1-sol` | 258000 | Sol routes advertise a million-token catalog window; 258000 is the project working window, matching the shipped Sol example. | 2026-11-10 |
| `deepseek-v4.1-flash` | 358000 | The primary OpenCode Go route advertises `W=1000000`; 358000 is the intended working window. | 2026-11-10 |

Constants: built-in cap `358000` (`ContextWindowPolicy.builtInMaxLimit`), local
fallback `16000` (`ContextWindowPolicy.localFallbackLimit`), smallest accepted
user cap `8192` (`ContextWindowPolicy.minimumMaxLimit`).

## Configuration

```yaml
# $SANAD_HOME/config.yaml
context:
  # Global ceiling for every resolved window. Default 358000. 0 = no cap.
  # A value between 1 and 8191 is rejected: it cannot hold a compaction summary
  # plus a usable request.
  maxLimit: 358000
  # Strongest layer, applied as-is and never capped. Merged key by key with the
  # shipped defaults: an entry replaces only its own key.
  modelLimits:
    gpt-6.1-sol: 300000
```

The section is strict: an unknown key, a negative or fractional `maxLimit`, a
`maxLimit` below the floor, or a non-positive `modelLimits` value fails the
loader instead of being half-applied. `config.yaml` is read at daemon startup;
an explicit provider model refresh re-reads it.

## One value per model

The effective window is the only user-facing number:

- `ModelOption.contextWindow` and the cached provider catalog carry the effective
  value.
- The Client context indicator and the compaction tile use it as the denominator.
- `sanad models` prints it for every model, and `--model` adds the provenance.
- Compaction planning (trigger, target, recovery) uses it.
- `model.snapshot_result` relays it and never a second number.

The provider's raw value before policy is kept only as internal evidence
(`ModelOption.contextWindowRaw`, cached as `context_window_raw`) so the
diagnostic can say the cap lowered it. `ProviderModelProjection` strips that key
from the model snapshot, so the wire carries a single `context_window`.

## Local and self-hosted routes

A route is local when its template is `ollama`, `lm-studio`, or `llama-cpp`, or
its endpoint is loopback (`localhost`, `127.0.0.0/8`, `::1`, `0.0.0.0`). A
remote self-hosted endpoint is treated as a cloud route: nothing local can be
probed, and the cap stays a safe upper bound.

Such a route owns its real window in the running engine. When the live probe
reports nothing usable, the window is `16000` rather than the cloud cap, because
an oversized request against a small local engine is a provider error instead of
a compaction.

## Diagnostics

`sanad models --model <id>` prints one provenance line, for example:

```text
context window: 258000 tokens (built-in)
context window: 358000 tokens (catalog; capped from 1000000)
context window: 1000000 tokens (user)
context window: 358000 tokens (unknown-cloud-cap)
context window: 16000 tokens (unknown-local-fallback)
```

`--json` carries the same facts additively: `context_window`,
`context_window_source`, and `context_window_capped_from` when the cap lowered the
value. No log line is emitted for any resolution.

## Verification

- `agent/test/core/config/context_window_resolution_test.dart` owns the policy
  matrix: merge, uncapped user values, cap on shipped/catalog/provider values,
  `maxLimit: 0`, cloud and local unknowns, and provenance strings.
- `agent/test/core/config_test.dart` owns the `config.yaml` schema and floor.
- `agent/test/core/provider_runtime/agent_runtime_service_test.dart` owns the
  adapter/catalog/models.dev outcomes.
- `agent/test/engine/runtime/compaction_request_factory_test.dart` owns the
  compaction window precedence and the no-double-cap rule.
- `agent/test/cli/models_command_test.dart` owns the diagnostic surface.
