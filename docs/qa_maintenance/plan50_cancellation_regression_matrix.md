# Plan 50 Cancellation Regression Matrix

Date: 2026-08-29
Status: verified in aggregation branch `feat/plan-50-run-cancellation`

## Provider interruption (50b)

| Scenario | Expected | Evidence |
|---|---|---|
| User Stop during provider hang | Request-owned transport closes; no retry | `provider_request_transport_test.dart` |
| Cancelled scope | `ProviderRequestCancelledException` maps to recovery cancelled | `agent_runner.dart` |

## Tool / shell cancellation (50c)

| Scenario | Expected | Evidence |
|---|---|---|
| User Stop during shell | `Command cancelled by user.` | `shell_execute_cancellation_test.dart` |
| Timeout vs cancel race | Single terminal message | `shell_execute_cancellation_test.dart` |
| Linux process group | Grandchild killed | `process_tree_controller_test.dart` |

## Terminal durability (50d)

| Scenario | Expected | Evidence |
|---|---|---|
| Stop with executing tools | Checkpoint + history `cancelled` | `ToolTerminalizationService` |
| Late tool completion | `_lockedCancelledResult` preserves cancel | `tool_execution_coordinator.dart` |
| Canonical payload | `tool_result.status = cancelled` | `agent_to_canonical.dart` |

## Client parity (50e)

| Scenario | Expected | Evidence |
|---|---|---|
| Live `tool_result cancelled` | No running spinner | `device_conversation_event_handler_test.dart` |
| `stopped` fallback | Running tools become cancelled | `device_conversation_event_handler_test.dart` |
| History hydration | `status` preserved | `session_query_handler.dart`, `unified_device_mapper.dart` |

## Integration notes

- Full E2E stop during live shell requires `sanad-dev` manual QA; unit/widget coverage proves protocol and projection contracts.
- Plan 54 background semantics are out of scope; foreground registration/release only.
