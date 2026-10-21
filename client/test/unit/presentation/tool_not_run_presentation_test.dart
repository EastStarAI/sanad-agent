import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/tool_presentation_helper.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

CanonicalEvent _shell(String terminalReason, {EventStatus status = EventStatus.error}) =>
    CanonicalEvent(
      id: 'e1',
      kind: EventKind.toolCall,
      status: status,
      text: '',
      timestamp: DateTime(2026),
      tool: {
        'name': 'shell_execute',
        'input': {'command': 'ls'},
        'output': jsonEncode({
          'isError': true,
          'output': 'not run',
          'terminal_reason': terminalReason,
        }),
      },
    );

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ar = lookupAppLocalizations(const Locale('ar'));

  test('a Protected refusal is shown as not run, in en and ar', () {
    for (final reason in ['protected_backend_unavailable', 'policy_unavailable']) {
      final event = _shell(reason);
      expect(ToolPresentationHelper.wasNotRun(event), isTrue);
      expect(ToolPresentationHelper.displayToolTitle(event, l10n: en), en.statusNotRun);
      expect(
        ToolPresentationHelper.displayToolTitle(event, l10n: ar, isArabic: true),
        ar.statusNotRun,
      );
    }
    expect(en.statusNotRun, 'Not run');
  });

  test('an ordinary failed command still reads Ran', () {
    final event = _shell('timed_out');
    expect(ToolPresentationHelper.wasNotRun(event), isFalse);
    expect(ToolPresentationHelper.displayToolTitle(event, l10n: en), 'Ran');
  });

  test('a call the user denied is shown as not run for any tool', () {
    for (final name in ['shell_execute', 'file_write', 'view_image']) {
      final event = CanonicalEvent(
        id: 'd1',
        kind: EventKind.toolCall,
        status: EventStatus.error,
        timestamp: DateTime(2026),
        tool: {
          'name': name,
          'input': {'command': 'rm -rf build', 'path': 'a.txt'},
          'output': 'Error executing tool: Exception: User denied permission for tool $name.',
          'errorCode': 'permission_denied',
        },
      );
      expect(ToolPresentationHelper.wasNotRun(event), isTrue, reason: name);
      expect(ToolPresentationHelper.displayToolTitle(event, l10n: en), 'Not run');
      expect(
        ToolPresentationHelper.displayToolTitle(event, l10n: ar, isArabic: true),
        ar.statusNotRun,
      );
    }
  });
}
