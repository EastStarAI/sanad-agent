import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/secrets_client.dart';
import 'package:sanad_client/features/settings/presentation/bloc/secrets_cubit.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages/secrets_page.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../helpers/pump_app.dart';

typedef _SetCall = ({String name, String value, String? description});

/// A scripted [SecretsClient] with the value-free surface of the real one.
///
/// It records every value it is asked to send (the transport legitimately sees
/// one) so a test can prove the cubit and the page never retain it, and it
/// projects a stored secret back the way the Agent does: metadata only.
class _FakeSecretsClient implements SecretsClient {
  final listCalls = <DeviceConfig>[];
  final setCalls = <_SetCall>[];
  final deleteCalls = <String>[];
  final changesController = StreamController<void>.broadcast();

  List<StoredSecret> secrets = <StoredSecret>[];
  SecretsException? listError;
  SecretsException? setError;
  SecretsException? deleteError;
  Completer<void>? listGate;

  @override
  Future<StoredSecretsSnapshot> list(DeviceConfig device) async {
    listCalls.add(device);
    await listGate?.future;
    final error = listError;
    if (error != null) throw error;
    return StoredSecretsSnapshot(secrets: List<StoredSecret>.of(secrets));
  }

  @override
  Future<StoredSecret> set(
    DeviceConfig device, {
    required String name,
    required String value,
    String? description,
  }) async {
    setCalls.add((name: name, value: value, description: description));
    final error = setError;
    if (error != null) throw error;
    final stored = _secret(name, description: description, source: SecretSource.user);
    secrets = [...secrets.where((secret) => secret.name != name), stored];
    return stored;
  }

  @override
  Future<SecretDeletionStatus> delete(DeviceConfig device, String name) async {
    deleteCalls.add(name);
    final error = deleteError;
    if (error != null) throw error;
    final existed = secrets.any((secret) => secret.name == name);
    secrets = secrets.where((secret) => secret.name != name).toList();
    return existed ? SecretDeletionStatus.deleted : SecretDeletionStatus.notFound;
  }

  @override
  Stream<void> changes(DeviceConfig device) => changesController.stream;
}

final _updatedAt = DateTime.utc(2026, 10, 23, 9, 40, 11);

StoredSecret _secret(
  String name, {
  String? description = 'Staging database password',
  SecretSource source = SecretSource.user,
}) => StoredSecret(
  name: name,
  description: description,
  source: source,
  createdAt: DateTime.utc(2026, 10, 22, 8, 12),
  updatedAt: _updatedAt,
);

DeviceConfig _device({bool isOnline = true}) =>
    DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: isOnline);

Future<AppLocalizations> _l10n(String locale) => AppLocalizations.delegate.load(Locale(locale));

TextField _field(WidgetTester tester, String key) => tester.widget<TextField>(find.byKey(Key(key)));

/// Lets a success toast finish its own timer so the test leaves no pending one.
Future<void> _drainToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const canary = 'canary-value-140-04-7c1d';
  late _FakeSecretsClient client;

  setUp(() async {
    client = _FakeSecretsClient();
    if (getIt.isRegistered<SecretsClient>()) await getIt.unregister<SecretsClient>();
    getIt.registerSingleton<SecretsClient>(client);
  });

  tearDown(() async {
    await client.changesController.close();
    if (getIt.isRegistered<SecretsClient>()) getIt.unregister<SecretsClient>();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    DeviceConfig? device,
  }) async {
    await pumpTestApp(
      tester,
      locale: locale,
      wrapWithToastification: true,
      child: SettingsSecretsPage(device: device ?? _device()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openAdd(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('secrets_add_btn')));
    await tester.pumpAndSettle();
  }

  group('list states', () {
    testWidgets('a skeleton shows while the first read is in flight', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      client.listGate = Completer<void>();

      await pumpTestApp(
        tester,
        child: SettingsSecretsPage(device: _device()),
      );
      await tester.pump();

      expect(find.byKey(const Key('secrets_loading')), findsOneWidget);
      expect(find.byKey(const Key('secrets_list')), findsNothing);

      client.listGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('secrets_list')), findsOneWidget);
    });

    testWidgets('an empty device shows the empty state and the add action', (tester) async {
      await pumpPage(tester);
      final l10n = await _l10n('en');

      expect(find.text(l10n.secretsEmpty), findsOneWidget);
      expect(find.byKey(const Key('secrets_empty')), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('secrets_add_btn'))).onPressed,
        isNotNull,
      );
    });

    testWidgets('a stored secret renders name, description, date and source', (tester) async {
      client.secrets = [
        _secret('DATABASE_PASSWORD'),
        _secret('STRIPE_KEY', description: null, source: SecretSource.agentRequest),
      ];
      await pumpPage(tester);
      final l10n = await _l10n('en');

      expect(find.text('DATABASE_PASSWORD'), findsOneWidget);
      expect(find.text('Staging database password'), findsOneWidget);
      expect(find.text(l10n.secretSourceUser), findsOneWidget);
      expect(find.text(l10n.secretSourceAgent), findsOneWidget);
      expect(find.text(l10n.secretNoDescription), findsOneWidget);
      expect(find.byKey(const Key('secret_row_DATABASE_PASSWORD')), findsOneWidget);
      expect(find.byKey(const Key('secret_replace_btn_DATABASE_PASSWORD')), findsOneWidget);
      expect(find.byKey(const Key('secret_delete_btn_DATABASE_PASSWORD')), findsOneWidget);

      final material = MaterialLocalizations.of(
        tester.element(find.byKey(const Key('secrets_list'))),
      );
      final expectedDate = l10n.secretUpdatedAt(
        material.formatShortDate(_updatedAt.toLocal()),
      );
      expect(find.text(expectedDate), findsNWidgets(2));
    });

    testWidgets('a typed failure shows localized copy and Retry re-reads once', (tester) async {
      client.listError = const SecretsException(SecretsErrorCode.internalError);
      await pumpPage(tester);
      final l10n = await _l10n('en');

      expect(find.byKey(const Key('secrets_error')), findsOneWidget);
      expect(find.text(l10n.secretsLoadFailed), findsOneWidget);
      expect(find.text(l10n.secretsInternalError), findsOneWidget);
      expect(client.listCalls, hasLength(1));

      client.listError = null;
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await tester.tap(find.byKey(const Key('secrets_retry_btn')));
      await tester.pumpAndSettle();

      expect(client.listCalls, hasLength(2));
      expect(find.text('DATABASE_PASSWORD'), findsOneWidget);
    });

    testWidgets('a transport failure presents the device as unavailable', (tester) async {
      client.listError = const SecretsException(SecretsErrorCode.deviceUnavailable);
      await pumpPage(tester);
      final l10n = await _l10n('en');

      expect(find.byKey(const Key('secrets_unavailable_banner')), findsOneWidget);
      expect(find.text(l10n.secretsUnavailable), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('secrets_add_btn'))).onPressed,
        isNull,
      );

      // The device is online, so the banner offers a retry that re-reads.
      client.listError = null;
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await tester.tap(find.byKey(const Key('secrets_retry_btn')));
      await tester.pumpAndSettle();
      expect(client.listCalls, hasLength(2));
      expect(find.byKey(const Key('secrets_list')), findsOneWidget);
    });

    testWidgets('an offline device asks for nothing and disables actions', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester, device: _device(isOnline: false));
      final l10n = await _l10n('en');

      expect(client.listCalls, isEmpty);
      expect(find.byKey(const Key('secrets_unavailable_banner')), findsOneWidget);
      expect(find.text(l10n.secretsUnavailable), findsOneWidget);
      expect(find.byKey(const Key('secrets_list')), findsNothing);
      expect(find.text('DATABASE_PASSWORD'), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('secrets_add_btn'))).onPressed,
        isNull,
      );
      // Nothing to retry while the device itself is offline.
      expect(find.byKey(const Key('secrets_retry_btn')), findsNothing);
    });

    testWidgets('going offline drops the list instead of showing it as current', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester);
      expect(find.byKey(const Key('secrets_list')), findsOneWidget);

      await pumpPage(tester, device: _device(isOnline: false));

      expect(find.byKey(const Key('secrets_list')), findsNothing);
      expect(find.byKey(const Key('secrets_unavailable_banner')), findsOneWidget);
      expect(client.listCalls, hasLength(1));
    });

    testWidgets('rebuilding the page never issues another list request', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester);
      expect(client.listCalls, hasLength(1));

      for (var rebuild = 0; rebuild < 5; rebuild++) {
        await pumpPage(tester);
      }

      expect(client.listCalls, hasLength(1));
    });
  });

  group('add', () {
    testWidgets('rejects an invalid name before any request', (tester) async {
      await pumpPage(tester);
      final l10n = await _l10n('en');

      await openAdd(tester);
      await tester.enterText(find.byKey(const Key('secret_name_input')), 'bad name!');
      await tester.enterText(find.byKey(const Key('secret_value_input')), canary);
      await tester.tap(find.byKey(const Key('secret_save_btn')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('secret_editor_dialog')), findsOneWidget);
      expect(_field(tester, 'secret_name_input').decoration?.errorText, l10n.secretInvalidName);
      expect(client.setCalls, isEmpty);
    });

    testWidgets('requires a value', (tester) async {
      await pumpPage(tester);
      final l10n = await _l10n('en');

      await openAdd(tester);
      await tester.enterText(find.byKey(const Key('secret_name_input')), 'DATABASE_PASSWORD');
      await tester.tap(find.byKey(const Key('secret_save_btn')));
      await tester.pumpAndSettle();

      expect(_field(tester, 'secret_value_input').decoration?.errorText, l10n.secretValueRequired);
      expect(client.setCalls, isEmpty);
    });

    testWidgets('rejects a value beyond the mirrored bound', (tester) async {
      await pumpPage(tester);
      final l10n = await _l10n('en');

      await openAdd(tester);
      await tester.enterText(find.byKey(const Key('secret_name_input')), 'DATABASE_PASSWORD');
      await tester.enterText(
        find.byKey(const Key('secret_value_input')),
        'a' * (SecretsClient.maxValueLength + 1),
      );
      await tester.tap(find.byKey(const Key('secret_save_btn')));
      await tester.pumpAndSettle();

      expect(
        _field(tester, 'secret_value_input').decoration?.errorText,
        l10n.secretValueTooLong(SecretsClient.maxValueLength),
      );
      expect(client.setCalls, isEmpty);
    });

    testWidgets('saves the typed value, clears the controller and shows the row', (tester) async {
      await pumpPage(tester);

      await openAdd(tester);
      await tester.enterText(find.byKey(const Key('secret_name_input')), 'DATABASE_PASSWORD');
      await tester.enterText(
        find.byKey(const Key('secret_description_input')),
        'Staging database password',
      );
      await tester.enterText(find.byKey(const Key('secret_value_input')), canary);
      final controller = _field(tester, 'secret_value_input').controller!;

      await tester.tap(find.byKey(const Key('secret_save_btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(client.setCalls.single, (
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'Staging database password',
      ));
      expect(find.byKey(const Key('secret_editor_dialog')), findsNothing);
      expect(controller.text, isEmpty);
      expect(find.text('DATABASE_PASSWORD'), findsOneWidget);

      // Drains the toast timer so the test leaves no pending timer behind.
      await _drainToast(tester);
    });

    testWidgets('clears the value controller on cancel', (tester) async {
      await pumpPage(tester);

      await openAdd(tester);
      await tester.enterText(find.byKey(const Key('secret_value_input')), canary);
      final controller = _field(tester, 'secret_value_input').controller!;

      await tester.tap(find.byKey(const Key('secret_cancel_btn')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('secret_editor_dialog')), findsNothing);
      expect(controller.text, isEmpty);
      expect(client.setCalls, isEmpty);
    });

    testWidgets('an Agent refusal stays in the dialog with localized copy', (tester) async {
      client.setError = const SecretsException(SecretsErrorCode.invalidSecretValue);
      await pumpPage(tester);
      final l10n = await _l10n('en');

      await openAdd(tester);
      await tester.enterText(find.byKey(const Key('secret_name_input')), 'DATABASE_PASSWORD');
      await tester.enterText(find.byKey(const Key('secret_value_input')), canary);
      final controller = _field(tester, 'secret_value_input').controller!;

      await tester.tap(find.byKey(const Key('secret_save_btn')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('secret_editor_dialog')), findsOneWidget);
      expect(find.text(l10n.secretValueInvalid), findsOneWidget);
      expect(controller.text, isEmpty);
      expect(find.text(canary), findsNothing);
    });
  });

  group('replace', () {
    testWidgets('opens with an empty value field and a read-only name', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester);
      final l10n = await _l10n('en');

      await tester.tap(find.byKey(const Key('secret_replace_btn_DATABASE_PASSWORD')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('secret_editor_dialog')), findsOneWidget);
      expect(find.text(l10n.replaceSecretNote), findsOneWidget);

      final nameField = _field(tester, 'secret_name_input');
      expect(nameField.readOnly, isTrue);
      expect(nameField.controller!.text, 'DATABASE_PASSWORD');

      final valueField = _field(tester, 'secret_value_input');
      expect(valueField.controller!.text, isEmpty);
      expect(valueField.obscureText, isTrue);

      // Nothing on this surface can reveal what is stored: the dialog never
      // received a value, and the field is empty before the user types.
      expect(client.setCalls, isEmpty);
    });

    testWidgets('the show/hide toggle only reveals what the user typed', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester);

      await tester.tap(find.byKey(const Key('secret_replace_btn_DATABASE_PASSWORD')));
      await tester.pumpAndSettle();
      expect(_field(tester, 'secret_value_input').obscureText, isTrue);

      await tester.enterText(find.byKey(const Key('secret_value_input')), canary);
      await tester.tap(find.byKey(const Key('secret_value_toggle')));
      await tester.pumpAndSettle();

      expect(_field(tester, 'secret_value_input').obscureText, isFalse);
      expect(find.text(canary), findsOneWidget);

      await tester.tap(find.byKey(const Key('secret_value_toggle')));
      await tester.pumpAndSettle();
      expect(_field(tester, 'secret_value_input').obscureText, isTrue);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('secret_value_input')),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isTrue,
      );
    });

    testWidgets('submits the new value and the description on screen', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD', description: 'Old description')];
      await pumpPage(tester);

      await tester.tap(find.byKey(const Key('secret_replace_btn_DATABASE_PASSWORD')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('secret_description_input')), 'New description');
      await tester.enterText(find.byKey(const Key('secret_value_input')), canary);
      await tester.tap(find.byKey(const Key('secret_save_btn')));
      await tester.pumpAndSettle();

      expect(client.setCalls.single, (
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'New description',
      ));
      expect(find.byKey(const Key('secret_editor_dialog')), findsNothing);
      expect(find.text('New description'), findsOneWidget);
      await _drainToast(tester);
    });
  });

  group('delete', () {
    testWidgets('asks for confirmation before deleting', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester);
      final l10n = await _l10n('en');

      await tester.tap(find.byKey(const Key('secret_delete_btn_DATABASE_PASSWORD')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('secret_delete_dialog')), findsOneWidget);
      expect(find.text(l10n.deleteSecretConfirm('DATABASE_PASSWORD')), findsOneWidget);
      expect(client.deleteCalls, isEmpty);

      await tester.tap(find.byKey(const Key('secret_delete_cancel_btn')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('secret_delete_dialog')), findsNothing);
      expect(client.deleteCalls, isEmpty);
      expect(find.byKey(const Key('secret_row_DATABASE_PASSWORD')), findsOneWidget);
    });

    testWidgets('confirming deletes the secret and removes the row', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester);
      final l10n = await _l10n('en');

      await tester.tap(find.byKey(const Key('secret_delete_btn_DATABASE_PASSWORD')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('secret_delete_confirm_btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(client.deleteCalls, ['DATABASE_PASSWORD']);
      expect(find.byKey(const Key('secret_delete_dialog')), findsNothing);
      expect(find.byKey(const Key('secret_row_DATABASE_PASSWORD')), findsNothing);
      expect(find.text(l10n.secretsEmpty), findsOneWidget);

      await _drainToast(tester);
    });
  });

  group('value containment', () {
    testWidgets('no cubit state emitted after a submit carries the value', (tester) async {
      await pumpPage(tester);
      final cubit = BlocProvider.of<SecretsCubit>(
        tester.element(find.byKey(const Key('secrets_page'))),
      );
      final seen = <SecretsState>[];
      final subscription = cubit.stream.listen(seen.add);
      addTearDown(subscription.cancel);

      await openAdd(tester);
      await tester.enterText(find.byKey(const Key('secret_name_input')), 'DATABASE_PASSWORD');
      await tester.enterText(find.byKey(const Key('secret_value_input')), canary);
      await tester.tap(find.byKey(const Key('secret_save_btn')));
      await tester.pumpAndSettle();

      // The value did travel to the transport, so the scan below is not vacuous.
      expect(client.setCalls.single.value, canary);
      final dumps = [
        for (final state in [...seen, cubit.state])
          '${state.toString()}|${state.secrets.map((secret) => secret.toJson()).toList()}'
              '|${state.secrets.map((secret) => secret.toString()).toList()}|${state.failure}',
      ];
      expect(dumps.where((dump) => dump.contains(canary)), isEmpty);
      expect(find.text(canary), findsNothing);
      await _drainToast(tester);
    });
  });

  group('localization', () {
    testWidgets('the list renders right-to-left in Arabic', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester, locale: const Locale('ar'));
      final ar = await _l10n('ar');

      expect(
        Directionality.of(tester.element(find.byKey(const Key('secrets_page')))),
        TextDirection.rtl,
      );
      expect(find.text(ar.secrets), findsOneWidget);
      expect(find.text(ar.addSecret), findsOneWidget);
      expect(find.text(ar.secretSourceUser), findsOneWidget);
    });

    testWidgets('both dialogs render right-to-left in Arabic', (tester) async {
      client.secrets = [_secret('DATABASE_PASSWORD')];
      await pumpPage(tester, locale: const Locale('ar'));
      final ar = await _l10n('ar');

      await tester.tap(find.byKey(const Key('secret_replace_btn_DATABASE_PASSWORD')));
      await tester.pumpAndSettle();

      expect(
        Directionality.of(tester.element(find.byKey(const Key('secret_editor_dialog')))),
        TextDirection.rtl,
      );
      expect(find.text(ar.replaceSecretNote), findsOneWidget);
      expect(find.text(ar.saveSecret), findsOneWidget);

      await tester.tap(find.byKey(const Key('secret_cancel_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('secret_delete_btn_DATABASE_PASSWORD')));
      await tester.pumpAndSettle();

      expect(
        Directionality.of(tester.element(find.byKey(const Key('secret_delete_dialog')))),
        TextDirection.rtl,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('secret_delete_dialog')),
          matching: find.text(ar.deleteSecret),
        ),
        findsOneWidget,
      );
      expect(find.text(ar.secretDeleteConfirmBtn), findsOneWidget);
    });
  });
}
