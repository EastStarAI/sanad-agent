import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

class _FakeAuthRepository implements IAuthRepository {
  bool loggedOut = false;

  @override
  Future<void> logout() async {
    loggedOut = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestAuthCubit extends AuthCubit {
  _TestAuthCubit(this.authRepo, {AuthState? initialState})
      : super(authRepository: authRepo) {
    if (initialState != null) {
      emit(initialState);
    }
  }

  final _FakeAuthRepository authRepo;
}

class _FakeLifecycleRepository implements AccountLifecycleRepository {
  bool deleteCalled = false;
  Object? deleteError;

  @override
  Future<AccountDeleteResult> deleteAccount() async {
    deleteCalled = true;
    if (deleteError != null) throw deleteError!;
    return const AccountDeleteResult(requestId: 'req-delete');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAuthRepository authRepo;
  late _TestAuthCubit authCubit;
  late _FakeLifecycleRepository lifecycleRepo;

  setUp(() {
    authRepo = _FakeAuthRepository();
    authCubit = _TestAuthCubit(
      authRepo,
      initialState: const AuthAuthenticated(
        username: 'reviewer@apple.com',
        displayName: 'Apple Reviewer',
        email: 'reviewer@apple.com',
        userId: 'usr-123',
        accessToken: 'mock-token',
        userCredits: 100,
        totalCredits: 100,
      ),
    );
    lifecycleRepo = _FakeLifecycleRepository();
  });

  tearDown(() async {
    await authCubit.close();
  });

  Future<void> pumpProfilePage(WidgetTester tester) async {
    await tester.pumpWidget(
      BlocProvider<AuthCubit>.value(
        value: authCubit,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ProfilePage(repository: lifecycleRepo),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders user info, sign out button, and delete account button', (tester) async {
    await pumpProfilePage(tester);

    expect(find.text('Apple Reviewer'), findsOneWidget);
    expect(find.text('reviewer@apple.com'), findsOneWidget);
    expect(find.byKey(const ValueKey('sign_out_btn')), findsOneWidget);
    expect(find.byKey(const ValueKey('delete_account_btn')), findsOneWidget);
  });

  testWidgets('tapping delete account shows confirmation dialog with Apple and local data notices', (tester) async {
    await pumpProfilePage(tester);

    await tester.tap(find.byKey(const ValueKey('delete_account_btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cancel_delete_account_btn')), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm_delete_account_btn')), findsOneWidget);
    expect(find.textContaining('permanently delete'), findsOneWidget);
    expect(find.textContaining('Apple ID'), findsOneWidget);
    expect(find.textContaining('Agent-owned'), findsOneWidget);
  });

  testWidgets('confirmation dialog is scrollable under high text scaling and small constraints', (tester) async {
    tester.view.physicalSize = const Size(500, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      BlocProvider<AuthCubit>.value(
        value: authCubit,
        child: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ProfilePage(repository: lifecycleRepo),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const ValueKey('delete_account_btn')), 50);
    await tester.tap(find.byKey(const ValueKey('delete_account_btn')));
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double-tapping delete account button only opens a single dialog', (tester) async {
    await pumpProfilePage(tester);

    // Tap once then immediately tap again before dialog settles
    await tester.tap(find.byKey(const ValueKey('delete_account_btn')));
    await tester.tap(find.byKey(const ValueKey('delete_account_btn')), warnIfMissed: false);
    await tester.pumpAndSettle();

    // Exactly one confirmation dialog should exist
    expect(find.byKey(const ValueKey('confirm_delete_account_btn')), findsOneWidget);

    // Dismissing once should leave no dialogs
    await tester.tap(find.byKey(const ValueKey('cancel_delete_account_btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('confirm_delete_account_btn')), findsNothing);
  });

  testWidgets('cancel button dismisses dialog without calling deleteAccount', (tester) async {
    await pumpProfilePage(tester);

    await tester.tap(find.byKey(const ValueKey('delete_account_btn')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cancel_delete_account_btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('confirm_delete_account_btn')), findsNothing);
    expect(lifecycleRepo.deleteCalled, isFalse);
    expect(authRepo.loggedOut, isFalse);
  });

  testWidgets('confirming deletion calls deleteAccount and logs out user', (tester) async {
    await pumpProfilePage(tester);

    await tester.tap(find.byKey(const ValueKey('delete_account_btn')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('confirm_delete_account_btn')));
    await tester.pumpAndSettle();

    expect(lifecycleRepo.deleteCalled, isTrue);
    expect(authRepo.loggedOut, isTrue);
  });

  testWidgets('unmounting widget mid-flight still dispatches logout', (tester) async {
    final completer = Completer<AccountDeleteResult>();
    var deleteInvoked = false;

    final deferredRepo = _DeferredLifecycleRepository(() {
      deleteInvoked = true;
      return completer.future;
    });

    await tester.pumpWidget(
      BlocProvider<AuthCubit>.value(
        value: authCubit,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ProfilePage(repository: deferredRepo),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('delete_account_btn')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('confirm_delete_account_btn')));
    await tester.pump(); // Start deletion, completer pending

    expect(deleteInvoked, isTrue);
    expect(authRepo.loggedOut, isFalse);

    // Replace tree to unmount ProfilePage while deletion is pending
    await tester.pumpWidget(
      BlocProvider<AuthCubit>.value(
        value: authCubit,
        child: const MaterialApp(home: Scaffold(body: Text('Unmounted'))),
      ),
    );
    await tester.pump();

    // Complete the pending backend deletion
    completer.complete(const AccountDeleteResult(requestId: 'req-unmounted'));
    await tester.pump();

    // logout must have been dispatched because authCubit was captured before await
    expect(authRepo.loggedOut, isTrue);
  });

  testWidgets('delete failure shows error and keeps user in session', (tester) async {
    lifecycleRepo.deleteError = const AccountLifecycleException('Backend deletion failed');

    await pumpProfilePage(tester);

    await tester.tap(find.byKey(const ValueKey('delete_account_btn')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('confirm_delete_account_btn')));
    await tester.pumpAndSettle();

    expect(lifecycleRepo.deleteCalled, isTrue);
    expect(authRepo.loggedOut, isFalse);
    expect(authCubit.state, isA<AuthAuthenticated>());
  });
}

class _DeferredLifecycleRepository implements AccountLifecycleRepository {
  _DeferredLifecycleRepository(this._onDelete);

  final Future<AccountDeleteResult> Function() _onDelete;

  @override
  Future<AccountDeleteResult> deleteAccount() => _onDelete();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
