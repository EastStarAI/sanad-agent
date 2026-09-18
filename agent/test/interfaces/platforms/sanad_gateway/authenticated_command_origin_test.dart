import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/authenticated_command_origin.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_gateway_behavior.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

final class _LoggingBehavior with SanadGatewayBehavior {
  @override
  final Logger logger = Logger('AuthenticatedOriginLoggingTest');

  @override
  SanadProtocolBridge get protocolBridge => throw UnsupportedError('unused');

  @override
  String get transportName => 'test';
}

void main() {
  group('AuthenticatedCommandOrigin', () {
    test('formats only allowlisted bounded metadata', () {
      final origin = AuthenticatedCommandOrigin.fromEnvelope({
        'origin_client': {
          'version': 1,
          'client_session_id': 'session-public-1',
          'client_instance_id': '11111111-1111-4111-8111-111111111111',
          'client_kind': 'desktop',
          'platform_family': 'macos',
          'display_name': 'Private Computer',
          'email': 'owner@example.com',
          'hostname': 'private-host',
          'ip': '192.0.2.1',
          'token': 'secret-token',
        },
        'payload': {'message': 'secret command'},
      });

      expect(origin.safeDisplay, 'authenticated desktop client on macos');
      expect(
        origin.displayTag,
        matches(RegExp(r'^desktop/macos#[0-9A-Z]{8}$')),
      );
      expect(origin.displayTag, isNot(contains('11111111')));
      expect(origin.safeDisplay, isNot(contains('session-public')));
      expect(origin.safeDisplay, isNot(contains('11111111')));
      expect(origin.safeDisplay, isNot(contains('Private Computer')));
      expect(origin.safeDisplay, isNot(contains('@')));
      expect(origin.safeDisplay, isNot(contains('private-host')));
      expect(origin.safeDisplay, isNot(contains('192.0.2.1')));
      expect(origin.safeDisplay, isNot(contains('secret')));
    });

    test(
      'gateway payload diagnostics contain structural metadata only',
      () async {
        const canary = 'private-origin-and-command-canary';
        final previousLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final records = <LogRecord>[];
        final StreamSubscription<LogRecord> subscription = Logger.root.onRecord
            .listen(records.add);
        addTearDown(() async {
          await subscription.cancel();
          Logger.root.level = previousLevel;
        });

        _LoggingBehavior().logFinePayload('Command payload:', {
          'payload': {'content': canary},
          'origin_client': {
            'client_instance_id': canary,
            'display_name': canary,
          },
        });
        await Future<void>.delayed(Duration.zero);

        final rendered = records.map((record) => record.message).join('\n');
        expect(rendered, contains('field_count=2'));
        expect(rendered, isNot(contains(canary)));
        expect(rendered, isNot(contains('origin_client')));
        expect(rendered, isNot(contains('content')));
      },
    );

    test('falls back for missing, malformed, and unknown versions', () {
      final fixtures = <Map<String, dynamic>>[
        {},
        {'origin_client': 'not-a-map'},
        {
          'origin_client': {'version': 99, 'client_kind': 'desktop'},
        },
        {
          'origin_client': {
            'version': 1,
            'client_kind': 'desktop\nforged',
            'platform_family': 'custom-platform',
            'client_session_id': 'x' * 1000,
            'client_instance_id': 'control\u0000character',
          },
        },
      ];

      for (final fixture in fixtures) {
        expect(
          AuthenticatedCommandOrigin.fromEnvelope(fixture).safeDisplay,
          'authenticated client',
        );
        expect(
          AuthenticatedCommandOrigin.fromEnvelope(fixture).displayTag,
          'client',
        );
      }
    });

    test(
      'displayTag includes platform and a privacy-safe stable reference',
      () {
        final webOrigin = AuthenticatedCommandOrigin.fromEnvelope({
          'origin_client': {
            'version': 1,
            'client_instance_id': '11111111-1111-4111-8111-111111111111',
            'client_kind': 'web',
            'platform_family': 'web',
          },
        });
        expect(webOrigin.displayTag, matches(RegExp(r'^web#[0-9A-Z]{8}$')));

        final mobileOrigin = AuthenticatedCommandOrigin.fromEnvelope({
          'origin_client': {
            'version': 1,
            'client_instance_id': '22222222-2222-4222-8222-222222222222',
            'client_kind': 'mobile',
            'platform_family': 'ios',
          },
        });
        expect(
          mobileOrigin.displayTag,
          matches(RegExp(r'^mobile/ios#[0-9A-Z]{8}$')),
        );

        final localOrigin = AuthenticatedCommandOrigin.fromLocalHello({
          'client_instance_id': '33333333-3333-4333-8333-333333333333',
          'metadata': {'client_kind': 'desktop', 'platform_family': 'windows'},
        });
        expect(
          localOrigin.displayTag,
          matches(RegExp(r'^desktop/windows#[0-9A-Z]{8}$')),
        );

        final unknownOrigin = AuthenticatedCommandOrigin.fromEnvelope({});
        expect(unknownOrigin.displayTag, 'client');
      },
    );

    test(
      'handleIncomingCommand logs concise client tag without redundant text',
      () async {
        final previousLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final records = <LogRecord>[];
        final subscription = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          await subscription.cancel();
          Logger.root.level = previousLevel;
        });

        final behavior = _LoggingBehavior();
        final bridge = PlatformRuntimeBridge();

        final origin = AuthenticatedCommandOrigin.fromLocalHello({
          'client_instance_id': '33333333-3333-4333-8333-333333333333',
          'metadata': {'client_kind': 'desktop', 'platform_family': 'macos'},
        });
        await behavior.handleIncomingCommand(
          envelope: {
            'command': CanonicalEventTypes.toolPermissionResponse,
            'payload': {'session_id': 's1'},
          },
          runtimeBridge: bridge,
          onResponse: (_) async {},
          authenticatedOrigin: origin,
        );

        final rendered = records.map((r) => r.message).join('\n');
        expect(
          rendered,
          contains(
            '⬇️ [${origin.displayTag}] Received execute_command: '
            'tool_permission_response',
          ),
        );
        expect(
          rendered,
          isNot(contains('33333333-3333-4333-8333-333333333333')),
        );
        expect(rendered, isNot(contains('from authenticated')));
        expect(rendered, isNot(contains('[socket]')));
        expect(rendered, isNot(contains('[ws]')));
      },
    );
  });
}
