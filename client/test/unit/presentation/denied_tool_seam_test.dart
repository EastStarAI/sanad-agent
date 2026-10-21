import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/canonical_timeline_reconciler.dart';
import 'package:sanad_client/features/conversations/presentation/utils/tool_presentation_helper.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Payload shapes are the ones the Agent emits: the live tool_result from
/// agent_to_canonical.dart and the history row from session_query_handler.dart.
void main() {
  final mapper = UnifiedDeviceMapper();
  final en = lookupAppLocalizations(const Locale('en'));
  final ar = lookupAppLocalizations(const Locale('ar'));
  const denial =
      'Error executing tool: Exception: User denied permission for tool shell_execute.';

  void expectNotRun(CanonicalEvent event) {
    expect(ToolPresentationHelper.wasNotRun(event), isTrue);
    expect(ToolPresentationHelper.displayToolTitle(event, l10n: en), 'Not run');
    expect(
      ToolPresentationHelper.displayToolTitle(event, l10n: ar, isArabic: true),
      ar.statusNotRun,
    );
  }

  test('live: a call tile flips to Not run when the denied result arrives', () {
    final call = mapper.mapLiveEvent({
      'event': 'tool_use',
      'payload': {
        'session_id': 's1',
        'tool': 'shell_execute',
        'input': '{"command":"rm -rf build"}',
        'tool_call_id': 'call-denied',
      },
    })!;
    expect(ToolPresentationHelper.displayToolTitle(call, l10n: en), isNot('Not run'));
    final result = mapper.mapLiveEvent({
      'event': 'tool_result',
      'payload': {
        'session_id': 's1',
        'tool': 'shell_execute',
        'output': denial,
        'isError': true,
        'errorCode': 'permission_denied',
        'status': 'error',
        'tool_call_id': 'call-denied',
      },
    })!;
    expect(CanonicalTimelineReconciler.matches(call, result), isTrue);
    expectNotRun(CanonicalTimelineReconciler.merge(call, result));
  });

  test('history: a reopened denied call shows Not run', () {
    final events = mapper.mapHistory([
      {
        'id': 1,
        'sender': 'ai',
        'type': 'tool_use',
        'tool': 'shell_execute',
        'input': '{"command":"rm -rf build"}',
        'tool_call_id': 'call-denied',
        'session_id': 's1',
        'created_at': '2026-10-21T00:00:00Z',
      },
      {
        'id': 2,
        'sender': 'ai',
        'type': 'tool_result',
        'tool': 'shell_execute',
        'output': denial,
        'isError': true,
        'errorCode': 'permission_denied',
        'status': 'error',
        'tool_call_id': 'call-denied',
        'session_id': 's1',
        'created_at': '2026-10-21T00:00:01Z',
      },
    ]);
    final terminal = events.lastWhere(
      (event) => event.kind == EventKind.toolCall && event.toolCallId == 'call-denied',
    );
    expectNotRun(terminal);
  });
}
