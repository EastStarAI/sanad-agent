// The font selected in Settings must reach widgets that used to build their own
// `TextStyle` with a hardcoded family. Each case below pumps a widget that
// previously ignored the selection and asserts the family it now renders with.

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/core/theme/app_themes.dart';
import 'package:sanad_client/core/theme/app_typography.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_workspace_warning.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/plan_task_list.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Family the bundled Cairo asset family resolves to in the theme.
const String cairoFamily = AppTypography.bundledCairoFamily;

/// Family `google_fonts` assigns to the Inter text theme.
const String interFamily = 'Inter_regular';

void main() {
  // Never touch the network from a widget test: the bundled Cairo default and
  // the monospace constant must both resolve without fetching.
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  tearDown(() {
    GoogleFonts.config.allowRuntimeFetching = true;
  });

  Widget host(
    AppFontFamily fontFamily,
    Widget child, {
    Locale locale = const Locale('en'),
  }) {
    return MaterialApp(
      theme: AppThemes.themeForStyle(
        AppThemeStyle.dark,
        fontFamily: fontFamily,
      ),
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('ar')],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: child),
    );
  }

  testWidgets('a widget that hardcoded Inter follows the selected font',
      (tester) async {
    await tester.pumpWidget(
      host(
        AppFontFamily.cairo,
        ComposerWorkspaceWarning(onRefresh: () {}),
      ),
    );
    await tester.pumpAndSettle();

    Text warning() => tester.widget<Text>(
          find.text('Select a workspace before your first Sanad Agent message.'),
        );

    expect(warning().style?.fontFamily, cairoFamily);

    await tester.pumpWidget(
      host(
        AppFontFamily.inter,
        ComposerWorkspaceWarning(onRefresh: () {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(warning().style?.fontFamily, interFamily);
  });

  testWidgets('a widget that hardcoded Roboto follows the selected font',
      (tester) async {
    final plan = <String, dynamic>{
      'tasks': [
        {'title': 'Ship it', 'status': 'pending'},
      ],
    };

    await tester.pumpWidget(
      host(AppFontFamily.cairo, PlanTaskList(plan: plan)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('Ship it')).style?.fontFamily,
      cairoFamily,
    );

    await tester.pumpWidget(
      host(AppFontFamily.inter, PlanTaskList(plan: plan)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('Ship it')).style?.fontFamily,
      interFamily,
    );
  });

  testWidgets('the System Default choice is not replaced by the Cairo default',
      (tester) async {
    await tester.pumpWidget(
      host(
        AppFontFamily.system,
        ComposerWorkspaceWarning(onRefresh: () {}),
      ),
    );
    await tester.pumpAndSettle();

    // `system` keeps the platform family the theme typography provides; it must
    // never be rewritten to the app default or to another bundled/fetched font.
    final systemFamily = tester
        .widget<Text>(
          find.text(
            'Select a workspace before your first Sanad Agent message.',
          ),
        )
        .style
        ?.fontFamily;
    expect(systemFamily, isNot(cairoFamily));
    expect(systemFamily, isNot(interFamily));
  });

  testWidgets('markdown prose follows the selection and code stays monospace',
      (tester) async {
    late MarkdownStyleSheet cairoSheet;
    late MarkdownStyleSheet interSheet;

    await tester.pumpWidget(
      host(
        AppFontFamily.cairo,
        Builder(
          builder: (context) {
            cairoSheet = MarkdownStyleHelper.getStyleSheet(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      host(
        AppFontFamily.inter,
        Builder(
          builder: (context) {
            interSheet = MarkdownStyleHelper.getStyleSheet(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Prose and blockquotes come from the theme text styles.
    expect(cairoSheet.p?.fontFamily, cairoFamily);
    expect(interSheet.p?.fontFamily, interFamily);

    // Code is fixed monospace and identical for both choices.
    final monospaceFamily = AppTypography.mono().fontFamily;
    expect(monospaceFamily, isNotNull);
    expect(cairoSheet.code?.fontFamily, monospaceFamily);
    expect(interSheet.code?.fontFamily, monospaceFamily);
  });

  testWidgets('an Arabic RTL pump applies the selected font', (tester) async {
    final plan = <String, dynamic>{
      'tasks': [
        {'title': 'Review the report', 'status': 'done'},
      ],
    };

    await tester.pumpWidget(
      host(
        AppFontFamily.cairo,
        PlanTaskList(plan: plan),
        locale: const Locale('ar'),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(PlanTaskList));
    expect(Directionality.of(context), TextDirection.rtl);
    expect(
      tester.widget<Text>(find.text('Review the report')).style?.fontFamily,
      cairoFamily,
    );
  });
}
