import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/core/presentation/widgets/app_background_wrapper.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppearanceCubit appearanceCubit;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    appearanceCubit = AppearanceCubit(const AppearanceState());
  });

  tearDown(() async {
    await appearanceCubit.close();
  });

  Widget buildTestApp({required Widget child}) {
    return BlocProvider.value(
      value: appearanceCubit,
      child: MaterialApp(
        home: child,
      ),
    );
  }

  testWidgets('AppBackgroundWrapper renders defaultTheme scaffoldBackgroundColor', (tester) async {
    await tester.pumpWidget(
      buildTestApp(
        child: const AppBackgroundWrapper(
          child: Text('Content'),
        ),
      ),
    );

    expect(find.text('Content'), findsOneWidget);
    expect(find.byType(Material), findsWidgets);
  });

  testWidgets('AppBackgroundWrapper renders solid color when solid Slate is selected', (tester) async {
    await appearanceCubit.updateBackgroundOption(AppBackgroundOption.solidSlate);

    await tester.pumpWidget(
      buildTestApp(
        child: const AppBackgroundWrapper(
          child: Text('Content'),
        ),
      ),
    );

    expect(find.text('Content'), findsOneWidget);
  });

  testWidgets('Nested AppBackgroundWrapper does not duplicate background when scope exists', (tester) async {
    await tester.pumpWidget(
      buildTestApp(
        child: const AppBackgroundWrapper(
          child: AppBackgroundWrapper(
            child: Text('Nested Content'),
          ),
        ),
      ),
    );

    expect(find.text('Nested Content'), findsOneWidget);
  });

  testWidgets('SettingsCard renders frosted translucent container when wallpaper is active', (tester) async {
    await appearanceCubit.updateBackgroundOption(AppBackgroundOption.natureForest);

    await tester.pumpWidget(
      buildTestApp(
        child: const SettingsCard(
          child: Text('Setting Item'),
        ),
      ),
    );

    expect(find.text('Setting Item'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('SettingsCard renders card when defaultTheme is active', (tester) async {
    await appearanceCubit.updateBackgroundOption(AppBackgroundOption.defaultTheme);

    await tester.pumpWidget(
      buildTestApp(
        child: const SettingsCard(
          child: Text('Setting Item'),
        ),
      ),
    );

    expect(find.text('Setting Item'), findsOneWidget);
    expect(find.byType(Container), findsWidgets);
  });
}
