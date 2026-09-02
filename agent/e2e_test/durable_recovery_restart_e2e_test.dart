// Gate F.2 — daemon-backed end-to-end verification of durable recovery.
//
// These tests prove that the production activation wired up in
// `bin/daemon.dart` (F.1) actually keeps the in-memory runtime state and
// the user-visible notice/queue/final-answer flow consistent across a real
// process restart, without falling back to:
//   - the `_handleE2eFixtureCommand` magic `__SANAD_E2E_SUCCESS_TURN__` shortcut
//     in `LocalDaemonServerPlatform` (a transport shortcut that bypasses
//     `AgentRunner`/`SessionRunOrchestrator`); or
//   - the `debug.runtime_notice_wait` protocol event fixture (also gated
//     by `SANAD_E2E_TEST_MODE`) that synthesizes a waiting notice.
//
// The fake LLM server in this file responds to the real OpenAI-compatible
// `/v1/chat/completions` endpoint. The daemon uses its real
// `BaseOpenAIAdapter`; the LLM just answers from a deterministic script. So
// every assertion about "the turn actually ran after recovery" is backed by
// either the fake server's request counter or a real persisted side effect,
// not by a transport-level fixture.
//
// IMPORTANT: this file binds a local gateway port and a fake LLM port per
// test. Run with `--concurrency=1` to prevent collisions, per the AGENTS.md
// contract for E2E/integration suites that bind system ports.
@Tags(<String>['e2e', 'gate-f'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/local_gateway_test_support.dart';

const _template = 'openai';
const _authMethod = 'api_key';
const _protocol = 'openai_compatible';

void main() {
  test(
    'F.2.1 waiting notice survives forced restart and auto-resumes at resume_at',
    () async {
      final h = await _RecoveryHarness.create();
      try {
        // Pre-script the fake LLM: first request returns a 429 so the
        // orchestrator emits a real waiting notice. After a forced process
        // restart, the restored resume_at timer must issue the second request
        // without a manual Retry command.
        h.fakeLlm.enqueueRateLimit(retryAfterSeconds: 5);
        h.fakeLlm.enqueueText('gate-f-recovered');

        final client1 = await h.startFirstDaemon();
        final sessionId = 'gate-f-f21-${_unique()}';

        await client1.sendThink(
          sessionId: sessionId,
          requestId: 'f21-think-${_unique()}',
          message: 'please answer me',
        );

        final notice1 = await client1.waitForRuntimeNotice(
          sessionId: sessionId,
          timeout: const Duration(seconds: 30),
        );
        expect(
          notice1.status,
          equals('waiting'),
          reason: 'first daemon must emit a real waiting notice',
        );

        await h.killFirstDaemon();

        final fake = h.fakeLlm;
        // The durable work item + notice MUST survive the restart; assert
        // against the database directly so we do not depend on a
        // websocket-raced live event after restore.
        final beforeRestart = await h.readDurableState(sessionId: sessionId);
        expect(
          beforeRestart.activeWorkItems.length,
          equals(1),
          reason: 'pre-restart work item must be in waiting/blocked',
        );
        expect(
          beforeRestart.activeWorkItems.single['state'],
          anyOf(equals('waiting'), equals('blocked')),
        );
        expect(beforeRestart.noticeStatus, equals('waiting'));

        final requestsBeforeAutoResume = fake.requestCount;
        final client2 = await h.startSecondDaemon();
        try {
          // Give restore a moment to promote the work item and rehydrate
          // the notice, then verify the durable state again and confirm that
          // session history hydration exposes the restored runtime notice.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final afterRestart = await h.readDurableState(sessionId: sessionId);
          expect(
            afterRestart.activeWorkItems.single['state'],
            equals('waiting'),
            reason: 'restore must promote the running work item to waiting',
          );
          expect(
            afterRestart.noticeStatus,
            equals('waiting'),
            reason: 'restore must keep the waiting notice row',
          );

          final history = await client2.loadSessionHistory(
            sessionId: sessionId,
            requestId: 'f21-history-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          final hydratedNotice =
              history['runtime_notice'] as Map<String, dynamic>?;
          expect(hydratedNotice, isNotNull);
          expect(hydratedNotice?['status'], equals('waiting'));

          final answer = await client2.waitForFinalAnswer(
            sessionId: sessionId,
            timeout: const Duration(seconds: 30),
          );
          expect(
            answer,
            contains('gate-f-recovered'),
            reason: 'real turn must hit the fake LLM and return its body',
          );
          expect(
            fake.requestCount,
            greaterThan(requestsBeforeAutoResume),
            reason:
                'resume_at expiry must call the fake LLM without a manual retry',
          );
        } finally {
          await client2.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'F.2.2 post-tool-result checkpoint does not execute the tool side effect twice after restart',
    () async {
      final h = await _RecoveryHarness.create();
      try {
        final fake = h.fakeLlm;
        final scheduledTaskLabel = 'gate-f-f22-task-${_unique()}';
        // Script: first request asks for `schedule_task`; the
        // post-tool-result continuation is rate-limited into a real WAITING
        // notice; after restart + retry the next request returns the final
        // answer. This proves the restart path resumes from the persisted
        // post-tool-result checkpoint instead of re-executing the tool.
        fake.enqueueToolCall(
          toolName: 'schedule_task',
          args: <String, dynamic>{
            'task': scheduledTaskLabel,
            'time': 'in 2 hours',
          },
          toolCallId: 'call-f22-${_unique()}',
        );
        fake.enqueueRateLimit(retryAfterSeconds: 60);
        fake.enqueueText('schedule_task-completed-once');

        final client1 = await h.startFirstDaemon();
        final sessionId = 'gate-f-f22-${_unique()}';
        try {
          await client1.sendThink(
            sessionId: sessionId,
            requestId: 'f22-think-${_unique()}',
            message: 'schedule this task exactly once',
          );

          final waiting = await client1.waitForRuntimeNotice(
            sessionId: sessionId,
            timeout: const Duration(seconds: 30),
          );
          expect(waiting.status, equals('waiting'));

          await h.stopFirstDaemon();
          expect(
            await h.countScheduledTasks(task: scheduledTaskLabel),
            equals(1),
            reason:
                'the real tool side effect must happen exactly once before restart',
          );

          final client2 = await h.startSecondDaemon();
          try {
            final history = await client2.loadSessionHistory(
              sessionId: sessionId,
              requestId: 'f22-history-${_unique()}',
              timeout: const Duration(seconds: 30),
            );
            expect(
              (history['runtime_notice'] as Map<String, dynamic>?)?['status'],
              equals('waiting'),
            );

            await client2.sendRetry(
              sessionId: sessionId,
              requestId: 'f22-retry-${_unique()}',
            );

            final answer = await client2.waitForFinalAnswer(
              sessionId: sessionId,
              timeout: const Duration(seconds: 45),
            );
            expect(answer, contains('schedule_task-completed-once'));
          } finally {
            await client2.close();
          }

          await h.stopSecondDaemon();
          expect(
            await h.countScheduledTasks(task: scheduledTaskLabel),
            equals(1),
            reason:
                'restart must not execute the real schedule_task side effect twice',
          );
        } finally {
          await client1.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'F.2.3 change-provider after restart routes the resumed turn to the new instance',
    () async {
      final h = await _RecoveryHarness.create();
      try {
        final fakeA = h.fakeLlm;
        final fakeB = h.fakeLlmSecondary;
        fakeA.enqueueRateLimit(retryAfterSeconds: 60);
        fakeB.enqueueText('switched-to-instance-b-ok');

        final client1 = await h.startFirstDaemon();
        final sessionId = 'gate-f-f23-${_unique()}';
        try {
          await client1.sendThink(
            sessionId: sessionId,
            requestId: 'f23-think-${_unique()}',
            message: 'this should hit the rate-limited instance',
            providerInstanceId: h.instanceIdPrimary,
          );

          final blocked = await client1.waitForRuntimeNotice(
            sessionId: sessionId,
            timeout: const Duration(seconds: 30),
          );
          expect(blocked.status, equals('waiting'));
          final primaryCallsBeforeRestart = fakeA.requestCount;

          await h.stopFirstDaemon();

          final client2 = await h.startSecondDaemon();
          try {
            final history = await client2.loadSessionHistory(
              sessionId: sessionId,
              requestId: 'f23-history-${_unique()}',
              timeout: const Duration(seconds: 30),
            );
            expect(
              (history['runtime_notice'] as Map<String, dynamic>?)?['status'],
              equals('waiting'),
            );

            await client2.sendContinueWithProvider(
              sessionId: sessionId,
              requestId: 'f23-change-${_unique()}',
              providerInstanceId: h.instanceIdSecondary,
            );

            final answer = await client2.waitForFinalAnswer(
              sessionId: sessionId,
              timeout: const Duration(seconds: 30),
            );
            expect(answer, contains('switched-to-instance-b-ok'));
            expect(
              fakeB.requestCount,
              greaterThanOrEqualTo(1),
              reason: 'secondary instance must receive the post-change turn',
            );
            expect(
              fakeA.requestCount,
              equals(primaryCallsBeforeRestart),
              reason:
                  'after provider change, the rate-limited instance must not receive any additional calls',
            );
          } finally {
            await client2.close();
          }
        } finally {
          await client1.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'F.2.4 auto-failover history keeps provider names and turn order after restart',
    () async {
      final h = await _RecoveryHarness.create(autoFailover: true);
      try {
        h.fakeLlm.enqueueRateLimit(retryAfterSeconds: 60);
        h.fakeLlmSecondary.enqueueText('automatic-failover-completed');

        final client1 = await h.startFirstDaemon();
        final sessionId = 'gate-f-f24-route-${_unique()}';
        final turnRequestId = 'f24-route-think-${_unique()}';
        try {
          await client1.sendThink(
            sessionId: sessionId,
            requestId: turnRequestId,
            message: 'trigger automatic provider failover',
            providerInstanceId: h.instanceIdPrimary,
          );
          final answer = await client1.waitForFinalAnswer(
            sessionId: sessionId,
            timeout: const Duration(seconds: 30),
          );
          expect(answer, contains('automatic-failover-completed'));

          await h.stopFirstDaemon();
          final client2 = await h.startSecondDaemon();
          try {
            final history = await client2.loadSessionHistory(
              sessionId: sessionId,
              requestId: 'f24-route-history-${_unique()}',
              timeout: const Duration(seconds: 30),
            );
            final messages = (history['messages'] as List)
                .cast<Map<String, dynamic>>();
            final userIndex = messages.indexWhere(
              (row) =>
                  row['type'] == 'user_message' &&
                  row['request_id'] == turnRequestId,
            );
            final transitionIndex = messages.indexWhere(
              (row) => row['type'] == 'session_route_transition',
            );
            expect(userIndex, isNot(-1));
            expect(transitionIndex, userIndex + 1);
            final transition = messages[transitionIndex];
            expect(
              transition['previous_provider_display_name'],
              'Gate F Primary',
            );
            expect(transition['provider_display_name'], 'Gate F Secondary');
            expect(transition['content'], contains('Gate F Primary'));
            expect(transition['content'], contains('Gate F Secondary'));
            expect(transition['content'], isNot(contains(h.instanceIdPrimary)));
            expect(
              transition['content'],
              isNot(contains(h.instanceIdSecondary)),
            );
          } finally {
            await client2.close();
          }
        } finally {
          await client1.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'F.2.5 stop after restart clears active work, notice, and durable state atomically',
    () async {
      final h = await _RecoveryHarness.create();
      try {
        h.fakeLlm.enqueueRateLimit(retryAfterSeconds: 60);
        final client1 = await h.startFirstDaemon();
        final sessionId = 'gate-f-f24-${_unique()}';
        try {
          await client1.sendThink(
            sessionId: sessionId,
            requestId: 'f24-think-${_unique()}',
            message: 'this should trigger a waiting notice',
          );
          await client1.waitForRuntimeNotice(
            sessionId: sessionId,
            timeout: const Duration(seconds: 30),
          );
          await h.stopFirstDaemon();
        } finally {
          await client1.close();
        }

        final client2 = await h.startSecondDaemon();
        try {
          final history = await client2.loadSessionHistory(
            sessionId: sessionId,
            requestId: 'f24-history-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          expect(
            (history['runtime_notice'] as Map<String, dynamic>?)?['status'],
            equals('waiting'),
          );

          await client2.sendStop(
            sessionId: sessionId,
            requestId: 'f24-stop-${_unique()}',
          );

          final cleared = await client2.waitForRuntimeNoticeCleared(
            sessionId: sessionId,
            timeout: const Duration(seconds: 30),
          );
          expect(cleared, isTrue);
          final stopped = await client2.waitForStopped(
            sessionId: sessionId,
            timeout: const Duration(seconds: 30),
          );
          expect(stopped, isTrue);
        } finally {
          await client2.close();
        }

        await h.stopSecondDaemon();

        final state = await h.readDurableState(sessionId: sessionId);
        expect(
          state.activeWorkItems,
          isEmpty,
          reason: 'stop must remove the active work item',
        );
        expect(
          state.suspendedRunExists,
          isFalse,
          reason: 'stop must remove the suspended run',
        );
        expect(
          state.noticeStatus,
          isNull,
          reason: 'stop must remove the active notice row',
        );
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'F.2.6 queue-only items are drained in FIFO order during restore',
    () async {
      final h = await _RecoveryHarness.create();
      try {
        final fake = h.fakeLlm;
        fake.enqueueText('first-fifo-answer');
        fake.enqueueText('second-fifo-answer');
        fake.enqueueText('third-fifo-answer');

        final sessionId = 'gate-f-f25-${_unique()}';
        await h.seedQueuedWorkItems(
          sessionId: sessionId,
          messages: const ['first-queued', 'second-queued', 'third-queued'],
          providerInstanceId: h.instanceIdPrimary,
        );

        final client = await h.startFirstDaemon();
        try {
          final answers = <String>[];
          for (var i = 0; i < 3; i++) {
            final answer = await client.waitForFinalAnswer(
              sessionId: sessionId,
              timeout: const Duration(seconds: 60),
            );
            answers.add(answer);
          }
          expect(
            answers,
            equals(<String>[
              'first-fifo-answer',
              'second-fifo-answer',
              'third-fifo-answer',
            ]),
            reason: 'queue-only restore must drain in strict FIFO order',
          );

          final state = await h.readDurableState(sessionId: sessionId);
          expect(state.activeWorkItems, isEmpty);
          expect(state.queuedWorkItems, isEmpty);
          expect(
            fake.requestCount,
            greaterThanOrEqualTo(3),
            reason: 'all three queued items must produce real LLM calls',
          );
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'F.2.7 provider Stop closes a partial SSE without blocking another session',
    () async {
      final h = await _RecoveryHarness.create();
      try {
        h.fakeLlm.enqueuePartialHang('partial-before-stop');
        h.fakeLlmSecondary.enqueueText('independent-session-completed');
        final client = await h.startFirstDaemon();
        final cancelledSessionId = 'gate-f-f27-cancel-${_unique()}';
        final independentSessionId = 'gate-f-f27-other-${_unique()}';
        try {
          await client.sendThink(
            sessionId: cancelledSessionId,
            requestId: 'f27-cancel-think-${_unique()}',
            message: 'stream until stopped',
            providerInstanceId: h.instanceIdPrimary,
          );
          await h.fakeLlm.waitForHangStart(
            timeout: const Duration(seconds: 30),
          );

          await client.sendThink(
            sessionId: independentSessionId,
            requestId: 'f27-other-think-${_unique()}',
            message: 'finish independently',
            providerInstanceId: h.instanceIdSecondary,
          );
          expect(
            await client.waitForFinalAnswer(
              sessionId: independentSessionId,
              timeout: const Duration(seconds: 30),
            ),
            contains('independent-session-completed'),
          );

          await client.sendStop(
            sessionId: cancelledSessionId,
            requestId: 'f27-stop-${_unique()}',
          );
          expect(
            await client.waitForStopped(
              sessionId: cancelledSessionId,
              timeout: const Duration(seconds: 30),
            ),
            isTrue,
          );
          await Future<void>.delayed(const Duration(milliseconds: 250));
          expect(
            h.fakeLlm.requestsEqualTo(h.fakeLlm.firstRequestBody),
            equals(1),
            reason: 'user cancellation must not retry the provider turn',
          );
          expect(
            h.fakeLlmSecondary.requestsEqualTo(h.fakeLlm.firstRequestBody),
            equals(0),
            reason: 'user cancellation must not fail over the provider turn',
          );

          final history = await client.loadSessionHistory(
            sessionId: cancelledSessionId,
            requestId: 'f27-history-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          expect(history['runtime_notice'], isNull);
        } finally {
          await client.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'F.2.8 live shell Stop kills descendants and preserves one cancelled terminal after restart',
    () async {
      final h = await _RecoveryHarness.create();
      try {
        final descendantPidFile = File('${h.workspaceDir.path}/descendant.pid');
        final toolCallId = 'call-f28-${_unique()}';
        h.fakeLlm.enqueueToolCall(
          toolName: 'shell_execute',
          args: <String, dynamic>{
            'command':
                'trap "" TERM; '
                'sh -c \'trap "" TERM; echo \$\$ > descendant.pid; '
                'while :; do echo draining; sleep 0.05; done\' & wait',
            'timeout_ms': 60000,
          },
          toolCallId: toolCallId,
        );

        final client1 = await h.startFirstDaemon();
        final sessionId = 'gate-f-f28-${_unique()}';
        try {
          await client1.sendThink(
            sessionId: sessionId,
            requestId: 'f28-think-${_unique()}',
            message: 'run the scripted shell command',
            workspaceId: h.workspaceDir.path,
          );
          await client1.waitForToolCall(
            sessionId: sessionId,
            toolName: 'shell_execute',
            timeout: const Duration(seconds: 30),
          );
          final descendantPid = await _waitForPidFile(
            descendantPidFile,
            timeout: const Duration(seconds: 10),
          );
          expect(await _processExists(descendantPid), isTrue);

          await client1.sendStop(
            sessionId: sessionId,
            requestId: 'f28-stop-${_unique()}',
          );
          final reconnectingClient = await _TestClient.connect(
            port: h.gatewayPort,
            sanadHomePath: h.sanadHome.path,
          );
          late final _CancellationSequence sequence;
          try {
            await reconnectingClient.sendStop(
              sessionId: sessionId,
              requestId: 'f28-duplicate-stop-${_unique()}',
            );
            sequence = await reconnectingClient.waitForCancellationSequence(
              sessionId: sessionId,
              toolCallId: toolCallId,
              timeout: const Duration(seconds: 30),
            );
          } finally {
            await reconnectingClient.close();
          }
          expect(sequence.eventOrder, equals(['cancelled', 'stopped', 'idle']));
          expect(sequence.terminalCount, equals(1));
          expect(sequence.terminal['status'], equals('cancelled'));
          expect(sequence.terminal['reason'], equals('user_stop'));
          expect(sequence.terminal['generation'], isA<int>());
          expect(sequence.terminal['revision'], isA<int>());
          expect(sequence.terminal['started_at'], isNotNull);
          expect(sequence.terminal['terminal_at'], isNotNull);
          expect(sequence.terminal['cleanup_outcome'], isNotNull);
          await _waitForProcessExit(
            descendantPid,
            timeout: const Duration(seconds: 5),
          );

          final liveHistory = await client1.loadSessionHistory(
            sessionId: sessionId,
            requestId: 'f28-live-history-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          _expectSingleCancelledTerminal(
            liveHistory,
            toolCallId: toolCallId,
            matching: sequence.terminal,
          );

          h.fakeLlm.enqueueText('new-turn-after-stop');
          await client1.sendThink(
            sessionId: sessionId,
            requestId: 'f28-next-${_unique()}',
            message: 'start a fresh turn',
            workspaceId: h.workspaceDir.path,
          );
          expect(
            await client1.waitForFinalAnswer(
              sessionId: sessionId,
              timeout: const Duration(seconds: 30),
            ),
            contains('new-turn-after-stop'),
          );
        } finally {
          await client1.close();
        }

        await h.stopFirstDaemon();
        final client2 = await h.startSecondDaemon();
        try {
          final restartedHistory = await client2.loadSessionHistory(
            sessionId: sessionId,
            requestId: 'f28-restart-history-${_unique()}',
            timeout: const Duration(seconds: 30),
          );
          _expectSingleCancelledTerminal(
            restartedHistory,
            toolCallId: toolCallId,
          );
        } finally {
          await client2.close();
        }
      } finally {
        await h.dispose();
      }
    },
    testOn: 'linux || mac-os',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'F.2.9 ordinary restart preserves ask-user suspension and resumes once',
    () async {
      final h = await _RecoveryHarness.create();
      try {
        const toolCallId = 'call-f29-ask-user';
        h.fakeLlm.enqueueToolCall(
          toolName: 'system_ask_user',
          args: const <String, dynamic>{
            'questions': <Map<String, dynamic>>[
              <String, dynamic>{
                'question': 'Continue after the ordinary restart?',
                'options': <String>['Continue', 'Pause', 'Cancel'],
              },
            ],
          },
          toolCallId: toolCallId,
        );
        h.fakeLlm.enqueueText('ask-user-resumed-after-ordinary-restart');
        h.fakeLlm.enqueueText('new-turn-admitted-after-suspended-resume');

        final client1 = await h.startFirstDaemon();
        final sessionId = 'gate-f-f29-${_unique()}';
        try {
          await client1.sendThink(
            sessionId: sessionId,
            requestId: 'f29-think-${_unique()}',
            message: 'Ask me before continuing.',
          );

          final firstRequestId = await client1.waitForPermissionRequest(
            sessionId: sessionId,
            toolName: 'system_ask_user',
            timeout: const Duration(seconds: 30),
          );

          final restart = await h.requestOrdinaryRestart(
            timeout: const Duration(seconds: 5),
          );
          expect(restart['success'], isTrue);
          expect(restart['outcome'], equals('safe'));

          final client2 = await h.startSecondDaemon();
          try {
            final historyBeforeAnswer = await client2.loadSessionHistory(
              sessionId: sessionId,
              requestId: 'f29-history-${_unique()}',
              timeout: const Duration(seconds: 30),
            );
            final messages = (historyBeforeAnswer['messages'] as List)
                .whereType<Map>()
                .map(Map<String, dynamic>.from)
                .toList(growable: false);
            expect(
              messages.any(
                (message) =>
                    message['type'] == 'tool_result' &&
                    message['tool_call_id'] == toolCallId,
              ),
              isFalse,
              reason: 'restart must not fabricate a result for Ask User',
            );

            await client2.sendPermissionResponse(
              sessionId: sessionId,
              requestId: firstRequestId,
              answer: 'Continue',
            );
            expect(
              await client2.waitForFinalAnswer(
                sessionId: sessionId,
                timeout: const Duration(seconds: 30),
              ),
              contains('ask-user-resumed-after-ordinary-restart'),
            );

            await client2.sendThink(
              sessionId: sessionId,
              requestId: 'f29-second-think-${_unique()}',
              message: 'Accept this new turn after the resumed answer.',
            );
            expect(
              await client2.waitForFinalAnswer(
                sessionId: sessionId,
                timeout: const Duration(seconds: 30),
              ),
              contains('new-turn-admitted-after-suspended-resume'),
              reason: 'the restored suspension projection must become idle',
            );
          } finally {
            await client2.close();
          }
        } finally {
          await client1.close();
        }
      } finally {
        await h.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

// ─── Test harness ─────────────────────────────────────────────────────────

class _RecoveryHarness {
  _RecoveryHarness._({
    required this.sanadHome,
    required this.sanadStateHome,
    required this.gatewayPort,
    required this.fakeLlm,
    required this.fakeLlmSecondary,
    required this.instanceIdPrimary,
    required this.instanceIdSecondary,
    required this.worktreeDir,
    required this.workspaceDir,
    required this.autoFailover,
  });

  final Directory sanadHome;
  final Directory sanadStateHome;
  final int gatewayPort;
  final FakeLlmServer fakeLlm;
  final FakeLlmServer fakeLlmSecondary;
  final String instanceIdPrimary;
  final String instanceIdSecondary;
  final Directory worktreeDir;
  final Directory workspaceDir;
  final bool autoFailover;

  Process? _firstDaemon;
  Process? _secondDaemon;
  bool _disposed = false;

  static const _baseGatewayPort = 58920;

  static Future<_RecoveryHarness> create({
    String templateId = _template,
    bool autoFailover = false,
  }) async {
    final worktreeDir = Directory.current;
    final sanadHome = await Directory.systemTemp.createTemp('sanad-f-home-');
    final sanadStateHome = await Directory.systemTemp.createTemp(
      'sanad-f-state-',
    );
    final workspaceDir = Directory('${sanadHome.path}/workspace')
      ..createSync(recursive: true);
    await File(
      '${workspaceDir.path}/AGENTS.md',
    ).writeAsString('Workspace owned by the cancellation recovery E2E test.');

    final workspaceState = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      SessionDB.fromState(
        workspaceState,
      ).saveWorkspace(path: workspaceDir.path, source: 'test');
    } finally {
      workspaceState.dispose();
    }
    await const WorkspacePolicyStore().savePermissionMode(
      workspaceDir.path,
      WorkspacePermissionMode.fullAccess,
    );

    final gatewayPort =
        _baseGatewayPort + (DateTime.now().microsecondsSinceEpoch % 200);
    final fake = await FakeLlmServer.start(port: 0);
    final fakeB = await FakeLlmServer.start(port: 0);

    final instanceIdPrimary = 'gate-f-inst-primary-${_unique()}';
    final instanceIdSecondary = 'gate-f-inst-secondary-${_unique()}';

    final h = _RecoveryHarness._(
      sanadHome: sanadHome,
      sanadStateHome: sanadStateHome,
      gatewayPort: gatewayPort,
      fakeLlm: fake,
      fakeLlmSecondary: fakeB,
      instanceIdPrimary: instanceIdPrimary,
      instanceIdSecondary: instanceIdSecondary,
      worktreeDir: worktreeDir,
      workspaceDir: workspaceDir,
      autoFailover: autoFailover,
    );

    await h._writeEnv();
    await h._seedProviderInstances(
      primaryBaseUrl: 'http://127.0.0.1:${fake.port}/v1',
      secondaryBaseUrl: 'http://127.0.0.1:${fakeB.port}/v1',
      primaryId: instanceIdPrimary,
      secondaryId: instanceIdSecondary,
      templateId: templateId,
    );
    await h._seedSecretForInstance(instanceIdPrimary);
    await h._seedSecretForInstance(instanceIdSecondary);
    return h;
  }

  Future<void> _writeEnv() async {
    final envFile = File('${sanadHome.path}/.env');
    final body = StringBuffer()
      ..writeln('SANAD_HOME=${sanadHome.path}')
      ..writeln('SANAD_STATE_HOME=${sanadStateHome.path}')
      ..writeln('ENABLE_LOCAL_GATEWAY=true')
      ..writeln('ENABLE_GATEWAY=false')
      ..writeln('LOCAL_GATEWAY_PORT=$gatewayPort')
      ..writeln('LOCAL_GATEWAY_HOST=127.0.0.1')
      ..writeln('ACTIVE_PROVIDER=$_template')
      ..writeln('LLM_API_KEY=fake-gate-f-test-key')
      ..writeln('OPENAI_API_KEY=fake-gate-f-test-key')
      ..writeln('OPENAI_MODEL=test-model')
      ..writeln('OPENAI_API_BASE=http://127.0.0.1:${fakeLlm.port}/v1')
      ..writeln('LLM_BASE_URL=http://127.0.0.1:${fakeLlm.port}/v1')
      ..writeln('LLM_MODEL=test-model')
      ..writeln('LOG_LEVEL=INFO')
      ..writeln('PROVIDER_AUTO_FAILOVER=$autoFailover');
    await envFile.writeAsString(body.toString());
  }

  Future<void> _seedProviderInstances({
    required String primaryBaseUrl,
    required String secondaryBaseUrl,
    required String primaryId,
    required String secondaryId,
    required String templateId,
  }) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final repo = ProviderInstanceRepository(stateDb);
      final now = DateTime.now();
      final primary = ProviderInstance(
        id: primaryId,
        templateId: templateId,
        displayName: 'Gate F Primary',
        protocol: _protocol,
        authMethod: _authMethod,
        baseUrl: primaryBaseUrl,
        defaultModel: 'test-model',
        status: 'ready',
        isDefault: true,
        createdAt: now,
        updatedAt: now,
      );
      final secondary = ProviderInstance(
        id: secondaryId,
        templateId: templateId,
        displayName: 'Gate F Secondary',
        protocol: _protocol,
        authMethod: _authMethod,
        baseUrl: secondaryBaseUrl,
        defaultModel: 'test-model',
        status: 'ready',
        isDefault: false,
        createdAt: now,
        updatedAt: now,
      );
      repo.createInstance(primary);
      repo.createInstance(secondary);
    } finally {
      stateDb.dispose();
    }
  }

  Future<void> _seedSecretForInstance(String instanceId) async {
    final secretFile = File('${sanadHome.path}/provider_secrets.json');
    final body = <String, dynamic>{
      'instances': <String, dynamic>{
        instanceId: <String, dynamic>{
          'instance_id': instanceId,
          'auth_method': _authMethod,
          'api_key': 'fake-gate-f-test-key',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      },
    };
    await secretFile.writeAsString(jsonEncode(body));
    try {
      await Process.run('chmod', ['600', secretFile.path]);
    } catch (_) {
      // Windows / sandbox: ignore.
    }
  }

  Future<_TestClient> startFirstDaemon() async {
    final proc = await _spawnDaemon();
    _firstDaemon = proc;
    final client = await _TestClient.connect(
      port: gatewayPort,
      sanadHomePath: sanadHome.path,
    );
    return client;
  }

  Future<_TestClient> startSecondDaemon() async {
    final proc = await _spawnDaemon();
    _secondDaemon = proc;
    final client = await _TestClient.connect(
      port: gatewayPort,
      sanadHomePath: sanadHome.path,
    );
    return client;
  }

  Future<Process> _spawnDaemon() async {
    final environment = <String, String>{
      ...Platform.environment,
      'SANAD_HOME': sanadHome.path,
      'SANAD_STATE_HOME': sanadStateHome.path,
      'ENABLE_LOCAL_GATEWAY': 'true',
      'ENABLE_GATEWAY': 'false',
      'LOCAL_GATEWAY_PORT': '$gatewayPort',
      'LOCAL_GATEWAY_HOST': '127.0.0.1',
      'LLM_API_KEY': 'fake-gate-f-test-key',
      'OPENAI_API_KEY': 'fake-gate-f-test-key',
      'LLM_MODEL': 'test-model',
      'OPENAI_MODEL': 'test-model',
      'OPENAI_API_BASE': 'http://127.0.0.1:${fakeLlm.port}/v1',
      'LLM_BASE_URL': 'http://127.0.0.1:${fakeLlm.port}/v1',
      'LOG_LEVEL': 'INFO',
      'PROVIDER_AUTO_FAILOVER': '$autoFailover',
    };
    final proc = await Process.start(
      Platform.resolvedExecutable,
      <String>['bin/daemon.dart'],
      workingDirectory: worktreeDir.path,
      environment: environment,
    );
    unawaited(
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => stderr.writeln('[daemon] $line'))
          .asFuture<void>(),
    );
    unawaited(
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => stderr.writeln('[daemon!] $line'))
          .asFuture<void>(),
    );
    await _waitForHealth(gatewayPort, sanadHome.path);
    return proc;
  }

  Future<void> stopFirstDaemon() async {
    final proc = _firstDaemon;
    _firstDaemon = null;
    if (proc == null) return;
    proc.kill(ProcessSignal.sigterm);
    try {
      await proc.exitCode.timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {
      proc.kill(ProcessSignal.sigkill);
    }
  }

  Future<void> killFirstDaemon() async {
    final proc = _firstDaemon;
    _firstDaemon = null;
    if (proc == null) return;
    proc.kill(ProcessSignal.sigkill);
    try {
      await proc.exitCode.timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  Future<Map<String, dynamic>> requestOrdinaryRestart({
    required Duration timeout,
  }) async {
    final proc = _firstDaemon;
    if (proc == null) {
      throw StateError('The first daemon is not running.');
    }
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse(
          'http://127.0.0.1:$gatewayPort/restart'
          '?timeout_seconds=${timeout.inSeconds}',
        ),
      );
      authorizeLocalGatewayTestRequest(request, sanadHome.path);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      expect(response.statusCode, equals(HttpStatus.ok), reason: body);
      await proc.exitCode.timeout(const Duration(seconds: 10));
      _firstDaemon = null;
      return payload;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopFirstDaemon();
    final proc = _secondDaemon;
    _secondDaemon = null;
    if (proc != null) {
      proc.kill(ProcessSignal.sigterm);
      try {
        await proc.exitCode.timeout(
          const Duration(seconds: 6),
          onTimeout: () {
            proc.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      } catch (_) {
        proc.kill(ProcessSignal.sigkill);
      }
    }
    await fakeLlm.stop();
    await fakeLlmSecondary.stop();
    if (sanadHome.existsSync()) {
      try {
        await sanadHome.delete(recursive: true);
      } catch (_) {}
    }
    if (sanadStateHome.existsSync()) {
      try {
        await sanadStateHome.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> stopSecondDaemon() async {
    final proc = _secondDaemon;
    _secondDaemon = null;
    if (proc == null) return;
    proc.kill(ProcessSignal.sigterm);
    try {
      await proc.exitCode.timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          proc.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {
      proc.kill(ProcessSignal.sigkill);
    }
  }

  Future<void> seedQueuedWorkItems({
    required String sessionId,
    required List<String> messages,
    required String providerInstanceId,
  }) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final repo = PersistedRuntimeStateRepository(stateDb.db);
      final now = DateTime.now();
      stateDb.db.execute(
        '''INSERT OR REPLACE INTO sessions (
          session_id, model, title, workspace_id, metadata,
          provider_id, thinking_mode, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        <Object?>[
          sessionId,
          'test-model',
          'Gate F F25',
          null,
          '{}',
          providerInstanceId,
          null,
          now.toUtc().toIso8601String(),
          now.toUtc().toIso8601String(),
        ],
      );
      var seq = 0;
      for (final message in messages) {
        seq++;
        repo.enqueueWorkItem(
          workItemId: 'wi-$sessionId-$seq',
          sessionId: sessionId,
          requestId: 'req-$sessionId-$seq',
          providerInstanceId: providerInstanceId,
          modelId: 'test-model',
          payload: <String, dynamic>{
            'message': message,
            'eventMetadata': <String, dynamic>{},
            'runId': 'run-$sessionId-$seq',
          },
          state: SessionWorkState.queued,
        );
      }
    } finally {
      stateDb.dispose();
    }
  }

  Future<_DurableStateSnapshot> readDurableState({
    required String sessionId,
  }) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final active = stateDb.db.select(
        '''SELECT work_item_id, state FROM session_work_items
           WHERE session_id = ? AND state IN
             ('running', 'resuming', 'waiting', 'blocked')''',
        <Object?>[sessionId],
      );
      final queued = stateDb.db.select(
        '''SELECT work_item_id FROM session_work_items
           WHERE session_id = ? AND state = 'queued' ''',
        <Object?>[sessionId],
      );
      final suspended = stateDb.db.select(
        'SELECT session_id FROM session_suspended_runs WHERE session_id = ?',
        <Object?>[sessionId],
      );
      final notice = stateDb.db.select(
        'SELECT status FROM session_runtime_notices WHERE session_id = ?',
        <Object?>[sessionId],
      );
      return _DurableStateSnapshot(
        activeWorkItems: active,
        queuedWorkItems: queued,
        suspendedRunExists: suspended.isNotEmpty,
        noticeStatus: notice.isNotEmpty
            ? notice.first['status'] as String
            : null,
      );
    } finally {
      stateDb.dispose();
    }
  }

  Future<int> countScheduledTasks({required String task}) async {
    final stateDb = AgentStateDatabase.atPath(sanadStateHome.path);
    try {
      final rows = stateDb.db.select(
        'SELECT id FROM scheduled_tasks WHERE task = ?',
        <Object?>[task],
      );
      return rows.length;
    } finally {
      stateDb.dispose();
    }
  }
}

class _DurableStateSnapshot {
  _DurableStateSnapshot({
    required this.activeWorkItems,
    required this.queuedWorkItems,
    required this.suspendedRunExists,
    required this.noticeStatus,
  });

  final List<Map<String, Object?>> activeWorkItems;
  final List<Map<String, Object?>> queuedWorkItems;
  final bool suspendedRunExists;
  final String? noticeStatus;
}

// ─── Fake LLM Server ──────────────────────────────────────────────────────

class _LlmResponse {
  const _LlmResponse.text(this.content)
    : toolName = null,
      toolArgs = null,
      toolCallId = null,
      isRateLimit = false,
      retryAfterSeconds = 0,
      partialHangContent = null;
  const _LlmResponse.toolCall({
    required String name,
    required Map<String, dynamic> args,
    required String id,
  }) : content = null,
       toolName = name,
       toolArgs = args,
       toolCallId = id,
       isRateLimit = false,
       retryAfterSeconds = 0,
       partialHangContent = null;
  const _LlmResponse.rateLimit(int seconds)
    : content = null,
      toolName = null,
      toolArgs = null,
      toolCallId = null,
      isRateLimit = true,
      retryAfterSeconds = seconds,
      partialHangContent = null;
  const _LlmResponse.partialHang(String content)
    : content = null,
      toolName = null,
      toolArgs = null,
      toolCallId = null,
      isRateLimit = false,
      retryAfterSeconds = 0,
      partialHangContent = content;

  final String? content;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final String? toolCallId;
  final bool isRateLimit;
  final int retryAfterSeconds;
  final String? partialHangContent;
}

class FakeLlmServer {
  FakeLlmServer._(this.port, this._server);

  final int port;
  final HttpServer _server;
  final List<_LlmResponse> _responses = [];
  final List<String> _requestBodies = [];
  Completer<void>? _hangStarted;
  int _requestCount = 0;

  int get requestCount => _requestCount;

  String get firstRequestBody => _requestBodies.first;

  int requestsEqualTo(String body) =>
      _requestBodies.where((candidate) => candidate == body).length;

  static Future<FakeLlmServer> start({required int port}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final fake = FakeLlmServer._(server.port, server);
    unawaited(fake._serve());
    return fake;
  }

  void enqueueText(String content) {
    _responses.add(_LlmResponse.text(content));
  }

  void enqueueToolCall({
    required String toolName,
    required Map<String, dynamic> args,
    required String toolCallId,
  }) {
    _responses.add(
      _LlmResponse.toolCall(name: toolName, args: args, id: toolCallId),
    );
  }

  void enqueueRateLimit({required int retryAfterSeconds}) {
    _responses.add(_LlmResponse.rateLimit(retryAfterSeconds));
  }

  void enqueuePartialHang(String content) {
    _hangStarted = Completer<void>();
    _responses.add(_LlmResponse.partialHang(content));
  }

  Future<void> waitForHangStart({required Duration timeout}) =>
      _hangStarted!.future.timeout(timeout);

  Future<void> _serve() async {
    await for (final request in _server) {
      try {
        if (request.method != 'POST' ||
            !request.uri.path.endsWith('/chat/completions')) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        _requestCount++;
        // Drain the request body so the connection can be safely re-used.
        _requestBodies.add(await utf8.decoder.bind(request).join());

        if (_responses.isEmpty) {
          await _writeError(
            request,
            HttpStatus.internalServerError,
            'fake-llm-out-of-scripted-responses',
          );
          continue;
        }
        final next = _responses.removeAt(0);
        if (next.partialHangContent != null) {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(
            'data: ${jsonEncode(<String, dynamic>{
              'id': 'chatcmpl-hang-${_unique()}',
              'object': 'chat.completion.chunk',
              'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              'model': 'fake-gate-f',
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'index': 0,
                  'delta': <String, dynamic>{'content': next.partialHangContent},
                  'finish_reason': null,
                },
              ],
            })}\n\n',
          );
          await request.response.flush();
          _hangStarted?.complete();
          try {
            while (true) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              request.response.write(': connection-probe\n\n');
              await request.response.flush();
            }
          } catch (_) {
            // The request-owned client was closed by cancellation.
          }
          continue;
        }
        if (next.isRateLimit) {
          request.response.statusCode = HttpStatus.tooManyRequests;
          request.response.headers.set(
            'Retry-After',
            '${next.retryAfterSeconds}',
          );
          await _writeJson(request, <String, dynamic>{
            'error': <String, dynamic>{
              'type': 'rate_limit',
              'code': 'rate_limit',
              'message':
                  'Fake LLM rate limit (Retry-After=${next.retryAfterSeconds}s)',
            },
          });
          continue;
        }
        if (next.toolName != null) {
          await _writeSse(
            request,
            _openAiChunks(
              content: '',
              toolName: next.toolName!,
              toolArgs: next.toolArgs ?? const <String, dynamic>{},
              toolCallId: next.toolCallId ?? 'call_${_unique()}',
            ),
          );
          continue;
        }
        await _writeSse(request, _openAiChunks(content: next.content ?? ''));
      } catch (error, stack) {
        stderr.writeln('[fake-llm] handler error: $error\n$stack');
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  List<String> _openAiChunks({
    required String content,
    String? toolName,
    Map<String, dynamic>? toolArgs,
    String? toolCallId,
  }) {
    final id = 'chatcmpl-${_unique()}';
    final model = 'fake-gate-f';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    String encode(Map<String, dynamic> data) => 'data: ${jsonEncode(data)}\n\n';

    final chunks = <String>[];
    chunks.add(
      encode({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': model,
        'choices': [
          {
            'index': 0,
            'delta': {'role': 'assistant'},
            'finish_reason': null,
          },
        ],
      }),
    );

    if (toolName != null) {
      final argsJson = jsonEncode(toolArgs ?? const <String, dynamic>{});
      chunks.add(
        encode({
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': model,
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': toolCallId,
                    'type': 'function',
                    'function': {'name': toolName, 'arguments': argsJson},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        }),
      );
      chunks.add(
        encode({
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': model,
          'choices': [
            {
              'index': 0,
              'delta': <String, dynamic>{},
              'finish_reason': 'tool_calls',
            },
          ],
        }),
      );
    } else {
      chunks.add(
        encode({
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': model,
          'choices': [
            {
              'index': 0,
              'delta': {'content': content},
              'finish_reason': null,
            },
          ],
        }),
      );
      chunks.add(
        encode({
          'id': id,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': model,
          'choices': [
            {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
          ],
        }),
      );
    }
    chunks.add(
      encode({
        'id': id,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': model,
        'choices': <Map<String, dynamic>>[],
        'usage': {
          'prompt_tokens': 1,
          'completion_tokens': 1,
          'total_tokens': 2,
        },
      }),
    );
    chunks.add('data: [DONE]\n\n');
    return chunks;
  }

  Future<void> _writeSse(HttpRequest request, List<String> chunks) async {
    request.response.headers.contentType = ContentType('text', 'event-stream');
    request.response.headers.set('Cache-Control', 'no-cache');
    for (final chunk in chunks) {
      request.response.write(chunk);
      await request.response.flush();
    }
    await request.response.close();
  }

  Future<void> _writeJson(HttpRequest request, Object body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _writeError(HttpRequest request, int status, String body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> stop() async {
    try {
      await _server.close(force: true);
    } catch (_) {}
  }
}

// ─── WebSocket test client ────────────────────────────────────────────────

class _TestClient {
  _TestClient._(this.socket, this.frames, this.port);

  final WebSocket socket;
  final StreamIterator<dynamic> frames;
  final int port;

  static Future<_TestClient> connect({
    required int port,
    required String sanadHomePath,
  }) async {
    final socket = await connectAuthenticatedLocalGateway(
      port: port,
      sanadHomePath: sanadHomePath,
    );
    final frames = StreamIterator<dynamic>(socket);
    if (!await frames.moveNext()) {
      throw StateError('Local daemon did not send a register_success frame');
    }
    final first = jsonDecode(frames.current as String) as Map<String, dynamic>;
    if (first['type'] != 'register_success') {
      throw StateError(
        'Expected register_success from local daemon, got: ${first['type']}',
      );
    }
    return _TestClient._(socket, frames, port);
  }

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
  }

  void _send(Map<String, dynamic> envelope) {
    socket.add(jsonEncode(envelope));
  }

  Future<void> sendThink({
    required String sessionId,
    required String requestId,
    required String message,
    String? providerInstanceId,
    String? model,
    String? workspaceId,
  }) async {
    final payload = <String, dynamic>{
      'request_id': requestId,
      'session_id': sessionId,
      'message': message,
      'model': model ?? 'test-model',
      'provider_instance_id': providerInstanceId,
      'workspace_id': ?workspaceId,
    };
    _send(<String, dynamic>{
      'type': 'execute_command',
      'command': 'think',
      'payload': payload,
    });
  }

  Future<void> sendRetry({
    required String sessionId,
    required String requestId,
  }) async {
    _send(<String, dynamic>{
      'type': 'protocol_event',
      'event': <String, dynamic>{
        'type': 'session.runtime_retry',
        'session_id': sessionId,
        'payload': {'request_id': requestId},
      },
    });
  }

  Future<void> sendContinueWithProvider({
    required String sessionId,
    required String requestId,
    required String providerInstanceId,
  }) async {
    _send(<String, dynamic>{
      'type': 'protocol_event',
      'event': <String, dynamic>{
        'type': 'session.runtime_continue_with_provider',
        'session_id': sessionId,
        'payload': <String, dynamic>{
          'request_id': requestId,
          'provider_instance_id': providerInstanceId,
        },
      },
    });
  }

  Future<void> sendStop({
    required String sessionId,
    required String requestId,
  }) async {
    _send(<String, dynamic>{
      'type': 'protocol_event',
      'event': <String, dynamic>{
        'type': 'session.runtime_stop',
        'session_id': sessionId,
        'payload': {'request_id': requestId},
      },
    });
  }

  Future<String> waitForPermissionRequest({
    required String sessionId,
    required String toolName,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event' ||
          frame['event'] != 'tool_permission_request') {
        continue;
      }
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      final eventSessionId =
          frame['session_id']?.toString() ?? payload['session_id']?.toString();
      if (eventSessionId != sessionId || payload['tool_name'] != toolName) {
        continue;
      }
      return payload['request_id'].toString();
    }
    throw TimeoutException(
      'Timed out waiting for permission request $toolName on $sessionId',
      timeout,
    );
  }

  Future<void> sendPermissionResponse({
    required String sessionId,
    required String requestId,
    required String answer,
  }) async {
    _send(<String, dynamic>{
      'type': 'execute_command',
      'command': 'tool_permission_response',
      'payload': <String, dynamic>{
        'session_id': sessionId,
        'request_id': requestId,
        'allowed': true,
        'scope': 'once',
        'decision': 'allow',
        'answer': answer,
      },
    });
  }

  Future<_RuntimeNotice> waitForRuntimeNotice({
    required String sessionId,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      final eventName = frame['event'] as String?;
      if (eventName != 'session.runtime_notice') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      if (payload['session_id'] != sessionId) continue;
      return _RuntimeNotice(
        status: payload['status']?.toString() ?? '',
        title: payload['title']?.toString() ?? '',
        message: payload['message']?.toString() ?? '',
        reason: payload['reason']?.toString() ?? '',
        actions:
            (payload['actions'] as List?)
                ?.map((a) => a.toString())
                .toList(growable: false) ??
            const <String>[],
      );
    }
    throw TimeoutException(
      'Timed out waiting for session.runtime_notice on $sessionId',
      timeout,
    );
  }

  Future<bool> waitForRuntimeNoticeCleared({
    required String sessionId,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      if (frame['event'] != 'session.runtime_notice_cleared') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      if (payload['session_id'] == sessionId) {
        return true;
      }
    }
    return false;
  }

  Future<bool> waitForStopped({
    required String sessionId,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      if (frame['event'] != 'stopped') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      final eventSessionId =
          frame['session_id']?.toString() ?? payload['session_id']?.toString();
      if (eventSessionId == sessionId) {
        return true;
      }
    }
    return false;
  }

  Future<String> waitForFinalAnswer({
    required String sessionId,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      final eventName = frame['event'] as String?;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      final eventSessionId =
          frame['session_id']?.toString() ?? payload['session_id']?.toString();
      if (eventSessionId != sessionId) continue;
      if (eventName == 'final_answer') {
        final content = payload['content']?.toString() ?? '';
        if (content.trim().isNotEmpty) return content.trim();
      }
    }
    throw TimeoutException(
      'Timed out waiting for final_answer on $sessionId',
      timeout,
    );
  }

  Future<Map<String, dynamic>> loadSessionHistory({
    required String sessionId,
    required String requestId,
    required Duration timeout,
  }) async {
    _send(<String, dynamic>{
      'type': 'execute_command',
      'command': 'get_session_history',
      'payload': <String, dynamic>{
        'session_id': sessionId,
        'request_id': requestId,
      },
    });

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      if (frame['event'] != 'session_history') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      if (payload['session_id'] == sessionId) {
        return payload;
      }
    }
    throw TimeoutException(
      'Timed out waiting for session_history on $sessionId',
      timeout,
    );
  }

  Future<void> waitForToolCall({
    required String sessionId,
    required String toolName,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      if (frame['event'] != 'tool_use') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      final eventSessionId =
          frame['session_id']?.toString() ?? payload['session_id']?.toString();
      if (eventSessionId != sessionId) continue;
      if (payload['tool'] == toolName || payload['tool_name'] == toolName) {
        return;
      }
    }
    throw TimeoutException(
      'Timed out waiting for tool_use($toolName) on $sessionId',
      timeout,
    );
  }

  Future<_CancellationSequence> waitForCancellationSequence({
    required String sessionId,
    required String toolCallId,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final order = <String>[];
    Map<String, dynamic>? terminal;
    var terminalCount = 0;
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final moved = await frames.moveNext().timeout(remaining);
      if (!moved) break;
      final frame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      if (frame['type'] != 'device_event') continue;
      final payload = frame['payload'] is Map
          ? Map<String, dynamic>.from(frame['payload'] as Map)
          : <String, dynamic>{};
      final eventSessionId =
          frame['session_id']?.toString() ?? payload['session_id']?.toString();
      if (eventSessionId != sessionId) continue;

      if (frame['event'] == 'tool_result' &&
          payload['tool_call_id'] == toolCallId &&
          payload['status'] == 'cancelled') {
        terminal = payload;
        terminalCount++;
        order.add('cancelled');
        continue;
      }
      if (frame['event'] == 'stopped') {
        order.add('stopped');
        continue;
      }
      if (frame['event'] == 'session.execution_state_changed' &&
          payload['state'] == 'idle') {
        order.add('idle');
        if (terminal != null) {
          return _CancellationSequence(
            eventOrder: order,
            terminal: terminal,
            terminalCount: terminalCount,
          );
        }
      }
    }
    throw TimeoutException(
      'Timed out waiting for cancelled/stopped/idle on $sessionId: $order',
      timeout,
    );
  }
}

class _CancellationSequence {
  const _CancellationSequence({
    required this.eventOrder,
    required this.terminal,
    required this.terminalCount,
  });

  final List<String> eventOrder;
  final Map<String, dynamic> terminal;
  final int terminalCount;
}

class _RuntimeNotice {
  _RuntimeNotice({
    required this.status,
    required this.title,
    required this.message,
    required this.reason,
    required this.actions,
  });
  final String status;
  final String title;
  final String message;
  final String reason;
  final List<String> actions;
}

// ─── Helpers ──────────────────────────────────────────────────────────────

int _unique() =>
    DateTime.now().microsecondsSinceEpoch ^ Random().nextInt(1 << 20);

Future<int> _waitForPidFile(File file, {required Duration timeout}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final pid = int.tryParse((await file.readAsString()).trim());
      if (pid != null) return pid;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw TimeoutException('Timed out waiting for ${file.path}', timeout);
}

Future<bool> _processExists(int pid) async {
  final result = await Process.run('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}

Future<void> _waitForProcessExit(int pid, {required Duration timeout}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!await _processExists(pid)) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('Owned descendant PID $pid survived cancellation cleanup');
}

void _expectSingleCancelledTerminal(
  Map<String, dynamic> history, {
  required String toolCallId,
  Map<String, dynamic>? matching,
}) {
  final terminals = (history['messages'] as List)
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .where(
        (message) =>
            message['type'] == 'tool_result' &&
            message['tool_call_id'] == toolCallId,
      )
      .toList(growable: false);
  expect(terminals, hasLength(1));
  final terminal = terminals.single;
  expect(terminal['status'], equals('cancelled'));
  expect(terminal['reason'], equals('user_stop'));
  for (final field in <String>[
    'run_id',
    'generation',
    'revision',
    'started_at',
    'terminal_at',
    'cleanup_outcome',
  ]) {
    expect(terminal[field], isNotNull, reason: 'history must preserve $field');
    if (matching != null) {
      expect(terminal[field], equals(matching[field]));
    }
  }
}

Future<void> _waitForHealth(int port, String sanadHomePath) async {
  final client = HttpClient();
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  Object? lastError;
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/health'),
        );
        authorizeLocalGatewayTestRequest(request, sanadHomePath);
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode == 200) {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          if (decoded['status'] == 'ok') return;
        }
        lastError = StateError('Unexpected health response: $body');
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  } finally {
    client.close(force: true);
  }
  throw StateError(
    'Local daemon health endpoint did not become ready: $lastError',
  );
}

// Silences the analyzer for the unused `Database` import in test-only paths.
// ignore: unused_element
void _ensureSqliteImport() {
  // ignore: unused_local_variable
  final Database? _ = null;
}
