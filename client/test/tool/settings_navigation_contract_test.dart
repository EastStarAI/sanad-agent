import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wide and compact settings expose a stable back control key', () {
    const keyDeclaration = "key: const Key('settings_back_to_conversations_btn')";
    final compactSource = File(
      'lib/features/settings/presentation/screens/settings_screen.dart',
    ).readAsStringSync();
    final wideSource = File(
      'lib/features/settings/presentation/widgets/settings_navigation.dart',
    ).readAsStringSync();

    // Back resolves the account's eligible landing route instead of hard-coding
    // Home: a zero-device mobile account would otherwise be stranded on a
    // device-less composer it cannot leave (live iOS pass, defect D-1).
    const eligibleLandingAction =
        'onPressed: () => context.go(AccountLanding.forCurrentAccount(context))';
    const directHomeAction = 'onPressed: () => context.go(AppRoutes.home)';

    expect(compactSource, contains(keyDeclaration));
    expect(compactSource, contains(eligibleLandingAction));
    expect(compactSource, isNot(contains(directHomeAction)));
    expect(wideSource, contains(keyDeclaration));
    expect(wideSource, contains(eligibleLandingAction));
    expect(wideSource, isNot(contains(directHomeAction)));
  });

  test('the conversation header exposes a stable navigation-menu key', () {
    // Live acceptance drives in-app navigation by key; a tooltip label is not a
    // stable selector once the header is reused across layouts.
    final header = File(
      'lib/features/conversations/presentation/widgets/conversation_header_actions.dart',
    ).readAsStringSync();

    expect(header, contains("key: const Key('nav_menu_btn')"));
  });
}
