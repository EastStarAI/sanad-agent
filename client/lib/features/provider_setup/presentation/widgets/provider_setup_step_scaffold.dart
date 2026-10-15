import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';

/// Keeps the current step actions visible in bounded overlays while allowing
/// Settings to retain ownership of its unbounded page scroll.
class ProviderSetupStepScaffold extends StatelessWidget {
  const ProviderSetupStepScaffold({
    required this.body,
    required this.footer,
    super.key,
  });

  final Widget body;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bodyWithPadding = Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: body,
        );
        if (!constraints.hasBoundedHeight) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [bodyWithPadding, footer],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: SingleChildScrollView(child: bodyWithPadding)),
            Builder(
              builder: (context) {
                final appearance = context.watch<AppearanceCubit?>()?.state;
                final isCustomBg = appearance != null && appearance.backgroundOption != AppBackgroundOption.defaultTheme;
                final footerColor = isCustomBg
                    ? (Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface).withValues(alpha: 0.60)
                    : Theme.of(context).colorScheme.surface;

                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: footerColor,
                    border: Border(
                      top: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: isCustomBg ? 0.25 : 1.0),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: footer,
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
