import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/widgets/user_profile_tile.dart';

class _FakeAuthRepository implements IAuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AuthCubit authCubit;
  late GoRouter router;

  setUp(() {
    authCubit = AuthCubit(authRepository: _FakeAuthRepository());
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: UserProfileTile()),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => Scaffold(
            body: Text('section:${state.uri.queryParameters['section']}'),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await authCubit.close();
  });

  Future<void> pumpTile(WidgetTester tester) {
    return tester.pumpWidget(
      BlocProvider<AuthCubit>.value(
        value: authCubit,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
  }

  testWidgets('avatar and name open Profile settings', (tester) async {
    await pumpTile(tester);

    await tester.tap(find.byKey(const Key('sidebar_profile_destination')));
    await tester.pumpAndSettle();

    expect(find.text('section:profile'), findsOneWidget);
  });

  testWidgets('gear opens General settings', (tester) async {
    await pumpTile(tester);

    await tester.tap(find.byKey(const Key('sidebar_general_settings_destination')));
    await tester.pumpAndSettle();

    expect(find.text('section:general'), findsOneWidget);
  });
}
