import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/full_access_confirmation_dialog.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/features/settings/data/workspace_security_client.dart';
import 'package:sanad_client/features/settings/presentation/widgets/workspace_security_card.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/utils/toast_utils.dart';

import '../../helpers/pump_app.dart';

class _FakeSecurityClient implements WorkspaceSecurityClient {
  _FakeSecurityClient(this.policy);

  WorkspacePolicy policy;
  int reads = 0;
  final changes = StreamController<WorkspacePolicy>.broadcast();

  @override
  Stream<WorkspacePolicy> watch(DeviceConfig device, String workspaceId) =>
      changes.stream;
  Object? nextUpdateError;
  final updates = <Map<String, Object?>>[];

  @override
  Future<WorkspacePolicy> read(DeviceConfig device, String workspaceId) async {
    reads++;
    return policy;
  }

  @override
  Future<WorkspacePolicy> update(
    DeviceConfig device,
    String workspaceId, {
    int? expectedRevision,
    WorkspacePermissionMode? permissionMode,
    WorkspaceExecutionMode? executionMode,
    WorkspaceHostDiscoveryPolicy? hostDiscoveryPolicy,
  }) async {
    updates.add({
      'expected_revision': expectedRevision,
      'execution_mode': executionMode?.value,
      'host_discovery_policy': hostDiscoveryPolicy?.value,
    });
    final error = nextUpdateError;
    if (error != null) {
      nextUpdateError = null;
      throw error;
    }
    policy = policy.copyWith(
      executionMode: executionMode,
      hostDiscoveryPolicy: hostDiscoveryPolicy,
      revision: policy.revision + 1,
    );
    return policy;
  }
}

void main() {
  final device = DeviceConfig(id: 'device-1', name: 'Laptop', isOnline: true);

  group('FullAccessConfirmationDialog', () {
    Future<List<bool>> openDialog(WidgetTester tester, {Locale? locale}) async {
      final results = <bool>[];
      await pumpTestApp(
        tester,
        locale: locale,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                results.add(await FullAccessConfirmationDialog.show(context)),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('explains the risks and Cancel keeps Default', (tester) async {
      final results = await openDialog(tester);
      expect(find.text('Turn on Full Access?'), findsOneWidget);
      expect(
        find.textContaining('without asking before each operation'),
        findsOneWidget,
      );
      expect(find.text('Access files and folders'), findsOneWidget);
      expect(find.text('Run terminal commands'), findsOneWidget);
      expect(find.text('Use the internet and connected tools'), findsOneWidget);
      expect(find.textContaining('prompt injection'), findsOneWidget);
      expect(find.textContaining('operating-system account'), findsOneWidget);

      await tester.tap(find.byKey(const Key('full_access_cancel_button')));
      await tester.pumpAndSettle();
      expect(results, [false]);
    });

    testWidgets('Turn On confirms exactly once', (tester) async {
      final results = await openDialog(tester);
      await tester.tap(find.byKey(const Key('full_access_confirm_button')));
      await tester.pumpAndSettle();
      expect(results, [true]);
      expect(find.byKey(const Key('full_access_confirmation_dialog')), findsNothing);
    });

    testWidgets('renders localized Arabic copy right-to-left', (tester) async {
      await openDialog(tester, locale: const Locale('ar'));
      expect(find.text('تفعيل الوصول الكامل؟'), findsOneWidget);
      final direction = Directionality.of(
        tester.element(find.byKey(const Key('full_access_confirmation_dialog'))),
      );
      expect(direction, TextDirection.rtl);
    });
  });

  group('WorkspaceSecurityCard', () {
    Future<_FakeSecurityClient> pumpCard(
      WidgetTester tester,
      WorkspacePolicy policy,
    ) async {
      final client = _FakeSecurityClient(policy);
      await pumpTestApp(
        tester,
        wrapWithToastification: true,
        child: SingleChildScrollView(
          child: WorkspaceSecurityCard(
            device: device,
            workspaceId: 'ws-1',
            client: client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return client;
    }

    testWidgets('an owner switches execution with the revision on screen', (tester) async {
      final client = await pumpCard(
        tester,
        const WorkspacePolicy(revision: 3, canWiden: true),
      );
      expect(find.byKey(const Key('workspace_security_stricter_only')), findsNothing);
      await tester.tap(find.text('Protected'));
      await tester.pumpAndSettle();
      expect(client.updates.single, {
        'expected_revision': 3,
        'execution_mode': 'protected',
        'host_discovery_policy': null,
      });
      expect(find.textContaining('no isolated backend yet'), findsOneWidget);

      await tester.tap(find.text('Direct Developer'));
      await tester.pumpAndSettle();
      expect(client.updates.last['expected_revision'], 4);
      expect(client.updates.last['execution_mode'], 'direct');
    });

    testWidgets('a policy change made elsewhere refreshes the card', (tester) async {
      final client = await pumpCard(
        tester,
        const WorkspacePolicy(revision: 2, canWiden: true),
      );
      expect(find.textContaining('Sanad credentials are removed'), findsOneWidget);
      client.changes.add(
        const WorkspacePolicy(
          executionMode: WorkspaceExecutionMode.protected,
          revision: 3,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('no isolated backend yet'), findsOneWidget);
      // The broadcast carries no canWiden; the reader's answer is kept.
      expect(find.byKey(const Key('workspace_security_stricter_only')), findsNothing);
      await tester.tap(find.text('Direct Developer'));
      await tester.pumpAndSettle();
      expect(client.updates.single['expected_revision'], 3);
    });

    testWidgets('segments carry driver keys that select their value', (tester) async {
      final client = await pumpCard(
        tester,
        const WorkspacePolicy(canWiden: true),
      );
      for (final key in [
        'workspace_security_mode_direct',
        'workspace_security_mode_protected',
        'workspace_security_discovery_owner_only',
        'workspace_security_discovery_disabled',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      await tester.tap(find.byKey(const Key('workspace_security_discovery_disabled')));
      await tester.pumpAndSettle();
      expect(client.updates.single['host_discovery_policy'], 'disabled');
    });

    testWidgets('segments expose their selected state to the driver', (tester) async {
      await pumpCard(
        tester,
        const WorkspacePolicy(
          executionMode: WorkspaceExecutionMode.protected,
          canWiden: true,
        ),
      );
      bool? selectedOf(String key) {
        // Mirrors driver_main.dart: the first Semantics below the keyed element.
        bool? selected;
        void visit(Element element) {
          final widget = element.widget;
          if (selected == null && widget is Semantics) {
            selected = widget.properties.selected;
          }
          element.visitChildren(visit);
        }
        tester.element(find.byKey(Key(key))).visitChildren(visit);
        return selected;
      }

      expect(selectedOf('workspace_security_mode_direct'), isFalse);
      expect(selectedOf('workspace_security_mode_protected'), isTrue);
      expect(selectedOf('workspace_security_discovery_owner_only'), isTrue);
      expect(selectedOf('workspace_security_discovery_disabled'), isFalse);
    });

    testWidgets('a non-owner can only make settings stricter', (tester) async {
      final client = await pumpCard(
        tester,
        const WorkspacePolicy(
          executionMode: WorkspaceExecutionMode.protected,
          hostDiscoveryPolicy: WorkspaceHostDiscoveryPolicy.disabled,
        ),
      );
      expect(find.byKey(const Key('workspace_security_stricter_only')), findsOneWidget);
      await tester.tap(find.text('Direct Developer'));
      await tester.tap(find.text('Owner only'));
      await tester.pumpAndSettle();
      expect(client.updates, isEmpty);
    });

    testWidgets('a rejected change shows the Agent reason and reloads', (tester) async {
      final client = await pumpCard(
        tester,
        const WorkspacePolicy(canWiden: true),
      );
      client.nextUpdateError = StateError(
        'Workspace policy changed (revision 9). Refresh and retry.',
      );
      final readsBefore = client.reads;
      final shown = <String>[];
      ToastUtils.debugOnShowError = shown.add;
      addTearDown(() => ToastUtils.debugOnShowError = null);
      await tester.tap(find.text('Disabled'));
      await tester.pumpAndSettle();
      expect(shown, ['Workspace policy changed (revision 9). Refresh and retry.']);
      expect(client.reads, readsBefore + 1);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a stale revision shows the localized refresh message', (tester) async {
      final client = await pumpCard(tester, const WorkspacePolicy(canWiden: true));
      client.nextUpdateError = DeviceCommandException('raw', code: 'stale_revision');
      final shown = <String>[];
      ToastUtils.debugOnShowError = shown.add;
      addTearDown(() => ToastUtils.debugOnShowError = null);
      await tester.tap(find.text('Disabled'));
      await tester.pumpAndSettle();
      expect(shown, [lookupAppLocalizations(const Locale('en')).workspacePolicyChangedRetry]);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a load failure offers retry', (tester) async {
      final client = _FailingClient();
      await pumpTestApp(
        tester,
        child: WorkspaceSecurityCard(
          device: device,
          workspaceId: 'ws-1',
          client: client,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Could not load workspace security settings.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace_security_retry')));
      await tester.pumpAndSettle();
      expect(client.reads, 2);
    });
  });
}

class _FailingClient extends _FakeSecurityClient {
  _FailingClient() : super(const WorkspacePolicy());

  @override
  Future<WorkspacePolicy> read(DeviceConfig device, String workspaceId) async {
    reads++;
    throw StateError('Device Laptop is not connected.');
  }
}
