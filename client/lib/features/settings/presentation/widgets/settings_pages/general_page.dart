import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/theme/theme_cubit.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/client_cli/presentation/widgets/client_cli_settings_card.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/infrastructure/platform/auto_update_service.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

import '../settings_widgets.dart';
import 'background_selection_grid.dart';

class GeneralPage extends StatefulWidget {
  const GeneralPage({super.key});

  @override
  State<GeneralPage> createState() => _GeneralPageState();
}

class _GeneralPageState extends State<GeneralPage> {
  bool _checking = false;
  String? _updateMessage;
  String? _currentVersion;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCurrentVersion());
  }

  Future<void> _loadCurrentVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        final version = packageInfo.version.trim();
        _currentVersion = version.isNotEmpty ? 'v$version' : null;
      });
    } catch (_) {
      if (getIt.isRegistered<DeviceConnectionCoordinator>()) {
        final expected = getIt<DeviceConnectionCoordinator>().expectedVersion;
        if (mounted && expected.isNotEmpty) {
          setState(() {
            _currentVersion = 'v$expected';
          });
        }
      }
    }
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _checking = true;
      _updateMessage = null;
    });
    final result = await getIt<AutoUpdateService>().checkForUpdates();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _updateMessage =
          result.message ??
          switch (result.status) {
            ClientUpdateStatus.updateOpened =>
              AppLocalizations.of(context)!.linuxUpdateManual,
            ClientUpdateStatus.upToDate => AppLocalizations.of(context)!.upToDate,
            ClientUpdateStatus.sourceManaged => AppLocalizations.of(context)!.sourceManagedUpdate,
            ClientUpdateStatus.artifactUnavailable =>
              AppLocalizations.of(context)!.updateNoPackage,
            ClientUpdateStatus.launchFailed => AppLocalizations.of(context)!.updateLaunchFailed,
            _ => AppLocalizations.of(context)!.updateStarted,
          };
    });
  }

  Future<void> _exportAppearance() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final appearance = context.read<AppearanceCubit>().state;
      final activeDeviceId = context.read<AppearanceCubit>().activeDeviceId;
      final fileName = activeDeviceId != null && activeDeviceId.isNotEmpty
          ? 'sanad-appearance-$activeDeviceId.json'
          : 'sanad-appearance.json';

      final saveLocation = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (saveLocation == null) return;

      final jsonContent = const JsonEncoder.withIndent('  ').convert(appearance.toJson());
      final xFile = XFile.fromData(
        utf8.encode(jsonContent),
        mimeType: 'application/json',
        name: fileName,
      );
      await xFile.saveTo(saveLocation.path);
      if (mounted) {
        ToastUtils.showSuccess(context, l10n.appearanceExported);
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError(context, e.toString());
      }
    }
  }

  Future<void> _importAppearance() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      const typeGroup = XTypeGroup(
        label: 'JSON',
        extensions: ['json'],
      );
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file == null) return;

      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        if (mounted) {
          ToastUtils.showError(context, l10n.appearanceImportFailed);
        }
        return;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (mounted) {
        await context.read<AppearanceCubit>().importAppearance(map);
        ToastUtils.showSuccess(context, l10n.appearanceImported);
      }
    } catch (_) {
      if (mounted) {
        ToastUtils.showError(context, l10n.appearanceImportFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<AppearanceCubit>().state;
    final l10n = AppLocalizations.of(context)!;
    return PageFrame(
      title: l10n.general,
      subtitle: l10n.settings,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (AppPlatform.isDesktop) ...[
            // Updates Card
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(context)!.updates,
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    AppPlatform.isLinux
                        ? AppLocalizations.of(context)!.updatesLinuxNote
                        : AppLocalizations.of(context)!.updatesAutoNote,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_currentVersion != null) ...[
                        Text(
                          AppLocalizations.of(context)!.currentVersion(_currentVersion!),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                      OutlinedButton.icon(
                        onPressed: _checking ? null : _checkForUpdates,
                        icon: _checking
                            ? const SizedBox.square(
                                dimension: 16,
                                child: AppProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.system_update_alt),
                        label: Text(AppLocalizations.of(context)!.checkForUpdates),
                      ),
                    ],
                  ),
                  if (_updateMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(_updateMessage!),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            const ClientCliSettingsCard(),
            const SizedBox(height: 16),
          ],
          // Language Card
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context)!.language,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  AppLocalizations.of(context)!.selectLanguage,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                BlocBuilder<LocaleCubit, Locale>(
                  builder: (context, locale) => SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<Locale>(
                      key: const Key('language_selector'),
                      segments: const [
                        ButtonSegment(
                          value: Locale('en'),
                          label: Text('English'),
                          icon: Icon(Icons.language_outlined),
                        ),
                        ButtonSegment(
                          value: Locale('ar'),
                          label: Text('العربية'),
                          icon: Icon(Icons.translate_outlined),
                        ),
                      ],
                      selected: {locale},
                      onSelectionChanged: (selection) =>
                          context.read<LocaleCubit>().updateLocale(selection.first),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Appearance & Typography
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l10n.appearance,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('appearance_export_btn'),
                          onPressed: _exportAppearance,
                          icon: const Icon(Icons.file_upload_outlined, size: 16),
                          label: Text(l10n.exportAppearance),
                        ),
                        OutlinedButton.icon(
                          key: const Key('appearance_import_btn'),
                          onPressed: _importAppearance,
                          icon: const Icon(Icons.file_download_outlined, size: 16),
                          label: Text(l10n.importAppearance),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.theme,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AppThemeStyle>(
                    key: const Key('theme_style_selector'),
                    segments: [
                      ButtonSegment(
                        value: AppThemeStyle.light,
                        label: Text(l10n.themeLight, key: const Key('theme_style_light_btn')),
                        icon: const Icon(Icons.light_mode_outlined),
                      ),
                      ButtonSegment(
                        value: AppThemeStyle.dark,
                        label: Text(l10n.themeDark, key: const Key('theme_style_dark_btn')),
                        icon: const Icon(Icons.dark_mode_outlined),
                      ),
                      ButtonSegment(
                        value: AppThemeStyle.midnight,
                        label: Text(l10n.themeMidnight, key: const Key('theme_style_midnight_btn')),
                        icon: const Icon(Icons.nightlight_round),
                      ),
                      ButtonSegment(
                        value: AppThemeStyle.sepia,
                        label: Text(l10n.themeSepia, key: const Key('theme_style_sepia_btn')),
                        icon: const Icon(Icons.menu_book_outlined),
                      ),
                    ],
                    selected: {appearance.themeStyle},
                    onSelectionChanged: (selection) {
                      final style = selection.first;
                      unawaited(context.read<AppearanceCubit>().updateThemeStyle(style));
                      unawaited(context.read<ThemeCubit>().updateTheme(style.themeMode));
                    },
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.primaryColor,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.selectPrimaryColor,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AppPrimaryColor>(
                    key: const Key('primary_color_selector_row1'),
                    showSelectedIcon: false,
                    emptySelectionAllowed: true,
                    segments: [
                      ButtonSegment(
                        value: AppPrimaryColor.blue,
                        label: Text(l10n.colorDefaultBlue, key: const Key('primary_color_blue_btn')),
                        icon: _ColorDot(color: AppPrimaryColor.blue.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.teal,
                        label: Text(l10n.colorTeal, key: const Key('primary_color_teal_btn')),
                        icon: _ColorDot(color: AppPrimaryColor.teal.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.green,
                        label: Text(l10n.colorGreen, key: const Key('primary_color_green_btn')),
                        icon: _ColorDot(color: AppPrimaryColor.green.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.cyan,
                        label: Text(l10n.colorCyan, key: const Key('primary_color_cyan_btn')),
                        icon: _ColorDot(color: AppPrimaryColor.cyan.colorForBrightness(Theme.of(context).brightness)),
                      ),
                    ],
                    selected: const {
                      AppPrimaryColor.blue,
                      AppPrimaryColor.teal,
                      AppPrimaryColor.green,
                      AppPrimaryColor.cyan,
                    }.contains(appearance.primaryColor)
                        ? {appearance.primaryColor}
                        : <AppPrimaryColor>{},
                    onSelectionChanged: (selection) {
                      if (selection.isNotEmpty) {
                        unawaited(context.read<AppearanceCubit>().updatePrimaryColor(selection.first));
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AppPrimaryColor>(
                    key: const Key('primary_color_selector_row2'),
                    showSelectedIcon: false,
                    emptySelectionAllowed: true,
                    segments: [
                      ButtonSegment(
                        value: AppPrimaryColor.purple,
                        label: Text(l10n.colorPurple, key: const Key('primary_color_purple_btn')),
                        icon: _ColorDot(color: AppPrimaryColor.purple.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.magenta,
                        label: Text(l10n.colorMagenta, key: const Key('primary_color_magenta_btn')),
                        icon: _ColorDot(color: AppPrimaryColor.magenta.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.orange,
                        label: Text(l10n.colorOrange, key: const Key('primary_color_orange_btn')),
                        icon: _ColorDot(color: AppPrimaryColor.orange.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.rose,
                        label: Text(l10n.colorRose, key: const Key('primary_color_rose_btn')),
                        icon: _ColorDot(color: AppPrimaryColor.rose.colorForBrightness(Theme.of(context).brightness)),
                      ),
                    ],
                    selected: const {
                      AppPrimaryColor.purple,
                      AppPrimaryColor.magenta,
                      AppPrimaryColor.orange,
                      AppPrimaryColor.rose,
                    }.contains(appearance.primaryColor)
                        ? {appearance.primaryColor}
                        : <AppPrimaryColor>{},
                    onSelectionChanged: (selection) {
                      if (selection.isNotEmpty) {
                        unawaited(context.read<AppearanceCubit>().updatePrimaryColor(selection.first));
                      }
                    },
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.fontFamily,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.selectFontFamily,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AppFontFamily>(
                    key: const Key('font_family_selector'),
                    segments: const [
                      ButtonSegment(
                        value: AppFontFamily.system,
                        label: Text('System'),
                      ),
                      ButtonSegment(
                        value: AppFontFamily.cairo,
                        label: Text('Cairo'),
                      ),
                      ButtonSegment(
                        value: AppFontFamily.inter,
                        label: Text('Inter'),
                      ),
                      ButtonSegment(
                        value: AppFontFamily.roboto,
                        label: Text('Roboto'),
                      ),
                    ],
                    selected: {appearance.fontFamily},
                    onSelectionChanged: (selection) =>
                        unawaited(context.read<AppearanceCubit>().updateFontFamily(selection.first)),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.fontSize,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.fontSizeDescription,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<AppFontSizeScale>(
                    key: const Key('font_size_selector'),
                    segments: [
                      ButtonSegment(
                        value: AppFontSizeScale.small,
                        label: Text(l10n.fontSizeSmall),
                      ),
                      ButtonSegment(
                        value: AppFontSizeScale.normal,
                        label: Text(l10n.fontSizeNormal),
                      ),
                      ButtonSegment(
                        value: AppFontSizeScale.large,
                        label: Text(l10n.fontSizeLarge),
                      ),
                      ButtonSegment(
                        value: AppFontSizeScale.extraLarge,
                        label: Text(l10n.fontSizeExtraLarge),
                      ),
                    ],
                    selected: {appearance.fontSizeScale},
                    onSelectionChanged: (selection) =>
                        unawaited(context.read<AppearanceCubit>().updateFontSizeScale(selection.first)),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.15),
                    ),
                  ),
                  child: Text(
                    l10n.previewText,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Background Selection Card
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.background,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.backgroundDescription,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                BackgroundSelectionGrid(
                  selected: appearance.backgroundOption,
                  themeStyle: appearance.themeStyle,
                  onSelected: (option) =>
                      unawaited(context.read<AppearanceCubit>().updateBackgroundOption(option)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      margin: const EdgeInsetsDirectional.only(end: 4),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.5),
          width: 1.5,
        ),
      ),
    );
  }
}
