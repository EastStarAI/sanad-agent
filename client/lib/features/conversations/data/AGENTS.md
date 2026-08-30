# Conversations Data Contract

## Scope
This contract applies to `client/lib/features/conversations/data/`.

## Repository and Client Ownership
- `ConversationCacheRepository` is the intent-based cache facade for presentation consumers; do not expose store merge internals or generation tokens.
- `ManagedConversationClientRegistry` preserves one conversation client per device.
- Commands must use explicit device and session identities through the owning gateway.
- Duplicate request identity must never replace an existing pending gateway waiter.
- Reverse tool results and suspension responses use the conversation device-command transport with raw request identity.

## Persistence
- Delegate cache persistence to `ConversationCachePersistence`; persist no secrets.
- Keep the schema versioned. Unknown future versions or corrupt payloads must invalidate safely to an empty snapshot.
- Hydrate the persistor before `runApp` and serialize writes so an older delayed save cannot overwrite a newer flush.
- Lifecycle pause, hidden, and detached transitions must flush pending writes.

## Fetch, Pagination, and Generations
- Keep workspace and conversation request generations independent.
- Reject stale responses after a newer generation, navigation request, deletion, or cache invalidation supersedes them.
- Unscoped reads must send `unscoped_only`.
- An authoritative first page replaces stale first-page data; appended pages merge by session identity.
- Key session query caches by full query identity: workspace, unscoped flag, limit, and cursor.
- Request-scoped session-list responses must not overwrite the shared default snapshot unless they represent the default unfiltered query.
- Keep legacy all-pages and explicit paginated queries as distinct cache identities. Identical concurrent query identities may share one transport request.
- New consumers must use explicit pagination rather than depend on compatibility get-all behavior.

## Hydration and Event Parity
- History repositories return canonical events directly; never round-trip them through legacy integer-id chat models.
- Preserve opaque string event ids and log only redacted correlation when hydration fails.
- Reconnect loads the active session history after session-list hydration so events emitted while disconnected become visible. A transport transition to `ready` is sufficient to trigger this reconciliation; never gate it on the stale `DeviceConfig.isOnline` value captured while the daemon was absent.
- Ignore a history response when navigation has moved to another requested session.
- Reapply live events after history hydration with request-id deduplication; legacy rows may use bounded same-session text/timestamp matching.
- Do not terminal-deduplicate running thinking events needed by later stream chunks.
- Hydrate runtime notice and queued messages together for the selected session, and retain lightweight recovery markers in session-list metadata.

## Thin-Client Dispatch
- Treat workspace UUID as identity; path, display name, and availability are authoritative mutable daemon projections.
- Send workspace identity and per-message preferences only; do not rebuild workspace bootstrap or system context in the client.
- Source slash commands, workspace trees, folder mutations, skills, web capabilities, and MCP catalogs from daemon query surfaces.
- Folder-mutation requests accept only their exact operation-specific canonical acknowledgment; timeout, error, or unrelated events remain failures.
- Workspace removal accepts only `workspace.removed` for the requested stable
  workspace id, then removes the workspace projection without deleting cached
  or daemon-owned conversation records.
- Workspace metadata mutations preserve correlated daemon failure reasons through the cache facade so presentation can render actionable feedback; never collapse them to `null` or a generic error.
- Client tool registration may advertise platform-provided tools only; do not rebroadcast daemon-owned workspace, skill, web, or MCP catalogs.

## Authoritative Responses
- Draft acceptance, queue mutation, pending-steer lifecycle, deletion, replay, stop, retry, and provider-route changes apply only from their matching authoritative response/event.
- Reply to suspension requests through `tool_permission_response` with explicit device/session ids, raw request id, optional denial comment, and text answer when required.
- Retain a pending suspension until authoritative resolution or terminal lifecycle delivery clears it.
- Latest-turn edit/retry transport uses daemon-authoritative replay intent keyed by the raw user request id.
