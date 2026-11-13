// Plan 174 review W2 — the notification copy title read must stay a single-row
// read.
//
// The notification dispatcher needs one thing from a session: its title. The
// `sessionTitle` callback registered in `lib/core/di.dart` used to call
// `SessionManager.getSession`, which decodes the whole message history and
// inserts (or evicts) an entry of the bounded eight-snapshot history cache — on
// every ask. This file states both halves of the fix: the owner read that must
// be used, and the wiring that must never go back to the hydrating read.
//
// The wiring half is static rather than behavioral on purpose: the composition
// root is a single function that registers a lazy singleton, and a behavioral
// test would have to boot the whole daemon to observe one callback. Scanning
// comment-stripped source pins the call that matters and cannot be satisfied by
// deleting the reason it exists.

import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('the notification title read never hydrates history', () {
    late Directory tempDir;
    late SessionManager sessionManager;
    late String sessionId;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'notification-title-read-test',
      );
      SessionManager.resetForTesting();
      setSanadHomeOverride(tempDir.path);
      sessionManager = SessionManager();
      sessionId = sessionManager.createSession('gpt-4o').sessionId;
      sessionManager.updateSessionTitle(sessionId, 'Fix the login redirect');
    });

    tearDown(() async {
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('getSessionTitle reads the title without a history snapshot', () {
      expect(sessionManager.hasHistorySnapshot(sessionId), isFalse);

      expect(
        sessionManager.getSessionTitle(sessionId),
        equals('Fix the login redirect'),
      );

      expect(
        sessionManager.hasHistorySnapshot(sessionId),
        isFalse,
        reason:
            'A title lookup must not populate the bounded history cache: that '
            'cache holds eight histories, so one notification per ask would '
            'evict the conversations the Client is actually reading.',
      );
    });

    test('an unknown session has no title and still caches nothing', () {
      expect(sessionManager.getSessionTitle('missing-session'), isNull);
      expect(sessionManager.hasHistorySnapshot('missing-session'), isFalse);
    });

    test('the hydrating read is what fills the cache', () {
      sessionManager.getSession(sessionId);

      expect(
        sessionManager.hasHistorySnapshot(sessionId),
        isTrue,
        reason:
            'This is the read the title lookup replaced, and this is the cache '
            'perturbation it caused.',
      );
    });
  });

  group('the composition root wires the single-row read', () {
    final source = File(
      '${_findPackageRoot().path}/lib/core/di.dart',
    ).readAsStringSync();

    test('the notification dispatcher resolves a title through the record '
        'read', () {
      final code = _codeOnly(source);

      expect(
        code,
        contains('getSessionTitle('),
        reason:
            'The notification dispatcher title source must stay the single-row '
            'lookup.',
      );
      expect(
        code,
        isNot(contains('.getSession(')),
        reason:
            '`getSession` hydrates message history and perturbs the bounded '
            'snapshot cache; no composition-root callback may use it.',
      );
    });
  });
}

/// [source] with line and block comments removed, so prose that names the
/// forbidden call neither trips the guard nor hides a real call.
String _codeOnly(String source) {
  final withoutBlocks = source.replaceAll(
    RegExp(r'/\*.*?\*/', dotAll: true),
    '',
  );
  return withoutBlocks
      .split('\n')
      .map((line) => line.replaceFirst(RegExp(r'//.*$'), ''))
      .join('\n');
}

Directory _findPackageRoot() {
  var directory = Directory.current;
  for (var depth = 0; depth < 4; depth++) {
    final hasPubspec = File('${directory.path}/pubspec.yaml').existsSync();
    final hasLib = Directory('${directory.path}/lib').existsSync();
    if (hasPubspec && hasLib) return directory;

    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }

  fail(
    'Could not locate the Agent package root from ${Directory.current.path}. '
    'Run this test from the Agent package root.',
  );
}
