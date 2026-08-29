# Durable Runtime State Contract

## Scope
This contract applies to `agent/lib/evolution/db/runtime/`.

## Aggregate Owners
- `SessionWorkItemRepository` owns durable work-item CRUD, FIFO claim, transitions, route rewrites, orphan cleanup, and cancellation.
- `RuntimeNoticeRepository` owns persisted runtime notices and hydration.
- `PendingInputRepository` owns pending-steer lifecycle and durable stop draft-recovery outcomes; pending steers are not work items.
- `RuntimeStateCleanup` composes cross-table session cleanup through owning repositories on the shared connection.
- `LegacyRuntimeStateMigrator` is migration compatibility only; new production work never enters legacy suspended/pending tables.

## Transition Graph
- Validate explicit work transitions rather than accepting any matching current state.
- Queued may become running or resuming; running may become waiting, blocked, completed, or queued during restart recovery; waiting/blocked may become resuming; resuming may become completed, waiting, or blocked.
- Every non-terminal state may become cancelled through Stop or owned cleanup. Same-state writes are metadata-only idempotent transitions; terminal states cannot leave themselves.
- Waiting and blocked remain active recovery states and cannot transition directly to completed without a claimed resume owner.
- Terminal self-transitions may be idempotent only where the aggregate contract permits.

## Admission and Commit
- `SessionExecutionStateCoordinator` owns atomic running-or-queued admission and terminal commit.
- Admission reads active durable work and inserts the next work item in one transaction.
- Terminal commit validates session, work item, run id, generation, and expected running/resuming state before assistant persistence and completion.
- Cancelled tool terminalization validates the same owner and commits checkpoint output plus history message in one transaction; a completed tool or repeated/stale writer is a no-op.
- Stop commits work cancellation before its acknowledgement, but may defer publishing the resulting idle/queued snapshot until cancelled tool terminals and `stopped` have been delivered.
- Stale claims and stale terminal commits are no-ops.

## Queue, Steer, and Recovery
- Queue promotion/deletion, route rewrite, pending-steer creation, and execution-snapshot recomputation commit through aggregate ownership.
- Every non-idle execution snapshot preserves the representative work item's accepted-turn start across queued, running, waiting, blocked, resuming, and stopping states; payload observations derive elapsed wall time from that stable start without revising authoritative state.
- Queue-to-steer promotion never creates a second active work item.
- Pending-steer revisions validate run and generation; only delivery failure may return delivering to pending.
- Restart treats a delivering steer as delivered only when durable history contains its raw request id; otherwise pending/delivering becomes draft recovery.
- Draft-recovery outcomes remain durable until the owning client acknowledges them.

## Route and Failover
- Route rewrite covers every non-terminal work item.
- Automatic failover atomically validates current owner, notice, request, and expected provider before claiming resuming and rewriting session/work routes.
- Snapshot provider display names into durable route transitions so history remains readable after provider rename/delete.
