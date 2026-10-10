import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_settings.dart';
import 'package:sanad_client/features/client_cli/presentation/bloc/client_cli_cubit.dart';
import 'package:sanad_client/features/client_cli/presentation/widgets/client_cli_settings_card.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

class _FakeClientCliCubit extends Cubit<ClientCliSettings> implements ClientCliCubit {
  final List<bool> setEnabledCalls = [];
  final List<String> setModeCalls = [];

  _FakeClientCliCubit([ClientCliSettings? initialState])
      : super(initialState ?? const ClientCliSettings());

  @override
  Future<void> setEnabled(bool enabled) async {
    setEnabledCalls.add(enabled);
    emit(state.copyWith(enabled: enabled));
  }

  @override
  Future<void> setPermissionMode(String mode) async {
    setModeCalls.add(mode);
    emit(state.copyWith(permissionMode: mode));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Widget buildTestWidget(_FakeClientCliCubit cubit) {
    return MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en')],
      home: Scaffold(
        body: BlocProvider<ClientCliCubit>.value(
          value: cubit,
          child: const SingleChildScrollView(
            child: ClientCliSettingsCard(),
          ),
        ),
      ),
    );
  }

  group('ClientCliSettingsCard', () {
    testWidgets('renders disabled state without permission mode selector', (tester) async {
      final cubit = _FakeClientCliCubit(const ClientCliSettings(enabled: false));
      await tester.pumpWidget(buildTestWidget(cubit));
      await tester.pumpAndSettle();

      expect(find.text('Client CLI'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      final switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.value, isFalse);

      // Permission segmented button should not be visible when disabled
      expect(find.byType(SegmentedButton<String>), findsNothing);
    });

    testWidgets('toggling switch calls setEnabled', (tester) async {
      final cubit = _FakeClientCliCubit(const ClientCliSettings(enabled: false));
      await tester.pumpWidget(buildTestWidget(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(cubit.setEnabledCalls, [true]);
    });

    testWidgets('when enabled, renders mode selector and switches mode', (tester) async {
      final cubit = _FakeClientCliCubit(
        const ClientCliSettings(
          enabled: true,
          permissionMode: ClientCliSettings.defaultMode,
        ),
      );
      await tester.pumpWidget(buildTestWidget(cubit));
      await tester.pumpAndSettle();

      final switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.value, isTrue);

      expect(find.byType(SegmentedButton<String>), findsOneWidget);
      expect(
        find.text('Ask for confirmation before executing commands on remote devices.'),
        findsOneWidget,
      );

      // Tap Full Access mode
      await tester.tap(find.text('Full access'));
      await tester.pumpAndSettle();

      expect(cubit.setModeCalls, [ClientCliSettings.fullAccessMode]);
    });
  });
}
