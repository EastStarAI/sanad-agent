import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/theme/theme_cubit.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/utils/device_ui_mapper.dart';
import 'package:sanad_client/features/mcp/presentation/screens/mcp_server_management_screen.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_flow.dart';
import 'package:sanad_client/features/settings/data/device_control_client.dart';
import 'package:sanad_client/features/settings/data/device_settings_client.dart';
import 'package:sanad_client/features/settings/data/device_skills_client.dart';
import 'package:sanad_client/infrastructure/platform/auto_update_service.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

import 'settings_widgets.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthCubit>().state;
    return PageFrame(
      title: AppLocalizations.of(context)!.profile,
      subtitle: AppLocalizations.of(context)!.profileSubtitle,
      child: SettingsCard(
        child: auth is AuthAuthenticated
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 28,
                    child: Text(
                      auth.displayName.characters.first.toUpperCase(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    auth.displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    auth.email,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () => context.read<AuthCubit>().logout(),
                    icon: const Icon(Icons.logout),
                    label: Text(AppLocalizations.of(context)!.signOut),
                  ),
                ],
              )
            : auth is AuthLoading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppLocalizations.of(context)!.signInPrompt),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(context.read<AuthCubit>().login()),
                    icon: const Icon(Icons.login),
                    label: Text(AppLocalizations.of(context)!.signIn),
                  ),
                ],
              ),
      ),
    );
  }
}

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
                                child: CircularProgressIndicator(strokeWidth: 2),
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
                Text(
                  l10n.appearance,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
                        label: Text(l10n.themeLight),
                        icon: const Icon(Icons.light_mode_outlined),
                      ),
                      ButtonSegment(
                        value: AppThemeStyle.dark,
                        label: Text(l10n.themeDark),
                        icon: const Icon(Icons.dark_mode_outlined),
                      ),
                      ButtonSegment(
                        value: AppThemeStyle.midnight,
                        label: Text(l10n.themeMidnight),
                        icon: const Icon(Icons.nightlight_round),
                      ),
                      ButtonSegment(
                        value: AppThemeStyle.sepia,
                        label: Text(l10n.themeSepia),
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
                        label: Text(l10n.colorDefaultBlue),
                        icon: _ColorDot(color: AppPrimaryColor.blue.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.teal,
                        label: Text(l10n.colorTeal),
                        icon: _ColorDot(color: AppPrimaryColor.teal.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.green,
                        label: Text(l10n.colorGreen),
                        icon: _ColorDot(color: AppPrimaryColor.green.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.cyan,
                        label: Text(l10n.colorCyan),
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
                        label: Text(l10n.colorPurple),
                        icon: _ColorDot(color: AppPrimaryColor.purple.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.magenta,
                        label: Text(l10n.colorMagenta),
                        icon: _ColorDot(color: AppPrimaryColor.magenta.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.orange,
                        label: Text(l10n.colorOrange),
                        icon: _ColorDot(color: AppPrimaryColor.orange.colorForBrightness(Theme.of(context).brightness)),
                      ),
                      ButtonSegment(
                        value: AppPrimaryColor.rose,
                        label: Text(l10n.colorRose),
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
                _BackgroundSelectionGrid(
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

class _BackgroundSelectionGrid extends StatelessWidget {
  final AppBackgroundOption selected;
  final AppThemeStyle themeStyle;
  final ValueChanged<AppBackgroundOption> onSelected;

  const _BackgroundSelectionGrid({
    required this.selected,
    required this.themeStyle,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final options = AppBackgroundOption.values;

    return LayoutBuilder(
      builder: (context, constraints) {
        const crossAxisCount = 3;
        const spacing = 12.0;
        final totalSpacing = spacing * (crossAxisCount - 1);
        final itemWidth = ((constraints.maxWidth - totalSpacing) / crossAxisCount).floorToDouble();

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: options.map((option) {
            final isSelected = option == selected;
            final label = switch (option) {
              AppBackgroundOption.defaultTheme => l10n.backgroundDefault,
              AppBackgroundOption.solidSlate => l10n.backgroundSlate,
              AppBackgroundOption.solidNavy => l10n.backgroundNavy,
              AppBackgroundOption.natureForest => l10n.backgroundForest,
              AppBackgroundOption.natureMountain => l10n.backgroundMountain,
              AppBackgroundOption.natureLake => l10n.backgroundLake,
            };

            return InkWell(
              key: Key('background_option_${option.name}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelected(option),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: itemWidth,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.25),
                    width: isSelected ? 2 : 1,
                  ),
                  color: isSelected
                      ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.15)
                      : Colors.transparent,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 70,
                        width: double.infinity,
                        child: _buildThumbnail(context, option),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isSelected) ...[
                          Icon(
                            Icons.check_circle,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildThumbnail(BuildContext context, AppBackgroundOption option) {
    final theme = Theme.of(context);
    final isDark = themeStyle == AppThemeStyle.dark || themeStyle == AppThemeStyle.midnight;

    if (option == AppBackgroundOption.defaultTheme) {
      return Container(
        color: theme.scaffoldBackgroundColor,
        child: Center(
          child: Icon(
            Icons.format_paint_outlined,
            color: theme.colorScheme.onSurfaceVariant,
            size: 24,
          ),
        ),
      );
    }

    if (!option.isWallpaper) {
      final solidColor = switch (option) {
        AppBackgroundOption.solidSlate =>
          isDark ? const Color(0xFF20262E) : const Color(0xFFE5E9EE),
        AppBackgroundOption.solidNavy =>
          isDark ? const Color(0xFF0B132B) : const Color(0xFFE0E7F5),
        _ => theme.scaffoldBackgroundColor,
      };
      return Container(color: solidColor);
    }

    // Wallpaper thumbnail with theme-adaptive barrier representation
    final scrimColor = switch (themeStyle) {
      AppThemeStyle.light => Colors.white.withValues(alpha: 0.70),
      AppThemeStyle.sepia => const Color(0xFFFBF0D9).withValues(alpha: 0.72),
      AppThemeStyle.dark => const Color(0xFF181818).withValues(alpha: 0.72),
      AppThemeStyle.midnight => const Color(0xFF000000).withValues(alpha: 0.78),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          option.assetPath!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(color: theme.scaffoldBackgroundColor),
        ),
        ColoredBox(color: scrimColor),
      ],
    );
  }
}

class EmptyDevicePage extends StatelessWidget {
  const EmptyDevicePage({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.devices_other_outlined, size: 52),
        const SizedBox(height: 12),
        Text(AppLocalizations.of(context)!.selectADevice, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(AppLocalizations.of(context)!.deviceSettingsPlaceholder),
      ],
    ),
  );
}

class DeviceOverviewPage extends StatefulWidget {
  const DeviceOverviewPage({
    super.key,
    required this.device,
    required this.isActive,
  });
  final DeviceConfig device;
  final bool isActive;

  @override
  State<DeviceOverviewPage> createState() => _DeviceOverviewPageState();
}

class _DeviceOverviewPageState extends State<DeviceOverviewPage> {
  static const _knownWebSearchProviders = {'ddg', 'serper'};

  final _client = getIt<DeviceSettingsClient>();
  final _runtimeClient = getIt<DeviceControlClient>();
  final _coordinator = getIt<DeviceConnectionCoordinator>();
  final _serperKeyController = TextEditingController();
  DeviceSettingsSnapshot? _settings;
  DeviceUpdateCheckSnapshot? _updateCheck;
  String? _error;
  String? _runtimeStatus;
  bool _saving = false;
  bool _runtimeBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(DeviceOverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device.id != widget.device.id) {
      _updateCheck = null;
      _runtimeStatus = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _serperKeyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final value = await _client.load(widget.device);
      if (mounted) setState(() => _settings = value);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _checkForAgentUpdates() async {
    if (_runtimeBusy || !widget.device.isOnline) return;
    setState(() {
      _runtimeBusy = true;
      _runtimeStatus = AppLocalizations.of(context)!.checkingForUpdates;
      _error = null;
    });
    try {
      final result = await _runtimeClient.checkForUpdates(widget.device);
      if (!mounted) return;
      setState(() {
        _updateCheck = result;
        _runtimeStatus = _checkStatusLabel(result);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _runtimeStatus = null);
        ToastUtils.showError(context, error.toString());
      }
    } finally {
      if (mounted) setState(() => _runtimeBusy = false);
    }
  }

  Future<void> _applyAgentUpdate() async {
    if (_runtimeBusy || !widget.device.isOnline) return;
    var check = _updateCheck;
    if (check == null || !check.updateAvailable) {
      await _checkForAgentUpdates();
      check = _updateCheck;
    }
    if (!mounted || check == null) return;
    if (check.sourceManaged) {
      ToastUtils.showError(
        context,
        check.message ?? AppLocalizations.of(context)!.sourceManagedAgent,
      );
      return;
    }
    if (!check.updateAvailable) {
      ToastUtils.showSuccess(
        context,
        check.message ?? 'The agent is already up to date.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update agent'),
        content: Text(
          'Install version ${check!.availableVersion} on ${widget.device.name}? '
          'The agent will wait for a safe checkpoint, then the connection will drop until it comes back online.',
        ),
        actions: [
          TextButton(
            key: const Key('dialog_cancel_update_button'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('dialog_confirm_update_button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _runtimeBusy = true;
      _runtimeStatus = 'Applying update…';
    });
    try {
      await _runtimeClient.applyUpdate(widget.device, check: check);
      await _runtimeClient.waitForReconnect(
        inventory: context.read<DeviceCubit>().agentRepository,
        deviceId: widget.device.id,
        expectedVersion: check.availableVersion,
      );
      if (!mounted) return;
      setState(() {
        _updateCheck = null;
        _runtimeStatus = 'Updated to ${check!.availableVersion}.';
      });
      ToastUtils.showSuccess(context, 'Agent updated to ${check.availableVersion}.');
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    } finally {
      if (mounted) setState(() => _runtimeBusy = false);
    }
  }

  Future<void> _restartRemoteAgent() async {
    if (_runtimeBusy || !widget.device.isOnline) return;
    final mode = await showDialog<AgentRestartMode>(
      context: context,
      builder: (context) => AgentRestartConfirmationDialog(
        deviceName: widget.device.name,
      ),
    );
    if (mode == null || !mounted) return;
    final force = mode == AgentRestartMode.force;

    setState(() {
      _runtimeBusy = true;
      _runtimeStatus = force ? 'Force restarting agent…' : 'Restarting agent…';
    });
    try {
      await _runtimeClient.restartAgent(widget.device, force: force);
      await _runtimeClient.waitForReconnect(
        inventory: context.read<DeviceCubit>().agentRepository,
        deviceId: widget.device.id,
      );
      if (!mounted) return;
      setState(() => _runtimeStatus = 'Agent is online again.');
      ToastUtils.showSuccess(context, 'Agent restarted.');
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    } finally {
      if (mounted) setState(() => _runtimeBusy = false);
    }
  }

  String _checkStatusLabel(DeviceUpdateCheckSnapshot result) {
    if (result.sourceManaged) {
      return result.message ?? 'This agent runs from source.';
    }
    if (result.updateAvailable) {
      return 'Update available: ${result.currentVersion} → ${result.availableVersion}.';
    }
    if (result.upToDate) {
      return 'Up to date (${result.currentVersion}).';
    }
    return result.message ?? 'Update check finished (${result.status}).';
  }

  Future<void> _update(Map<String, dynamic> changes) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final value = await _client.update(widget.device, changes);
      if (!mounted) return;
      setState(() => _settings = value);
      if (value.restartRequired) {
        ToastUtils.showSuccess(
          context,
          'Setting saved. The agent is restarting…',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleComputerUse(bool enabled) async {
    if (enabled && !(_settings?.computerUsePermissionsGranted ?? false)) {
      final granted = await _client.requestComputerUsePermissions(
        widget.device,
      );
      if (!granted) {
        if (mounted) {
          setState(
            () => _error = 'Accessibility or screen-recording permission was not granted.',
          );
        }
        return;
      }
    }
    await _update({'computer_use_enabled': enabled});
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final route = _coordinator.resolve(widget.device).scope;
    return PageFrame(
      title: widget.device.name,
      subtitle: 'Device overview and runtime preferences.',
      child: Column(
        children: [
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: widget.device.iconBackground(context),
                    child: widget.device.buildIcon(context, size: 16),
                  ),
                  title: DeviceNameEditor(
                    device: widget.device,
                    onRename: (name) => context.read<DeviceCubit>().renameAgent(
                      widget.device,
                      name,
                    ),
                  ),
                  subtitle: Text(
                    '${widget.device.isOnline ? 'Online' : 'Offline'} · ${route == ConnectionScope.local ? 'Local connection' : 'Sanad Gateway'}',
                  ),
                  trailing: widget.isActive
                      ? const Chip(label: Text('Active'))
                      : FilledButton.tonal(
                          onPressed: () => context.read<DeviceCubit>().setActiveAgent(widget.device.id),
                          child: const Text('Set as active'),
                        ),
                ),
                const Divider(),
                DetailRow(
                  label: 'Device ID',
                  value: widget.device.hardwareId ?? widget.device.id,
                ),
                DetailRow(
                  label: 'Agent version',
                  value: widget.device.metadata?['version']?.toString() ?? _coordinator.expectedVersion,
                ),
                DetailRow(
                  label: 'Current route',
                  value: route == ConnectionScope.local ? 'Local' : 'Cloud',
                ),
                if (_runtimeStatus != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _runtimeStatus!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('device_check_updates_button'),
                      onPressed: !widget.device.isOnline || _runtimeBusy ? null : _checkForAgentUpdates,
                      icon: const Icon(Icons.system_update_alt),
                      label: const Text('Check for updates'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('device_apply_update_button'),
                      onPressed: !widget.device.isOnline || _runtimeBusy ? null : _applyAgentUpdate,
                      icon: const Icon(Icons.upgrade),
                      label: const Text('Update agent'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('device_restart_agent_button'),
                      onPressed: !widget.device.isOnline || _runtimeBusy ? null : _restartRemoteAgent,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Restart agent'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (settings == null && _error == null) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            ),
          if (settings != null) ...[
            SettingsCard(
              child: Column(
                children: [
                  if (route == ConnectionScope.local)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Cloud Connection'),
                      subtitle: Text(
                        settings.cloudConnection.managedExternally
                            ? 'Managed by the process environment.'
                            : 'Allow this agent to connect through Sanad Gateway. Changing this restarts the agent.',
                      ),
                      value: settings.cloudConnection.enabled,
                      onChanged: _saving || settings.cloudConnection.managedExternally
                          ? null
                          : (value) => _update({'cloud_connection_enabled': value}),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Computer Use'),
                    subtitle: Text(
                      settings.computerUsePermissionsGranted
                          ? 'OS permissions are granted.'
                          : 'Accessibility and screen-recording permissions are required.',
                    ),
                    value: settings.computerUse.enabled,
                    onChanged: _saving || settings.computerUse.managedExternally ? null : _toggleComputerUse,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Web Search',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    // Guard against providers the client does not yet know about
                    // (e.g. the agent reports 'brave' but the client build only
                    // ships ddg/serper). Dropping the unknown initialValue keeps
                    // the dropdown usable instead of tripping Flutter's
                    // "exactly one item" assertion.
                    initialValue:
                        _knownWebSearchProviders.contains(
                          settings.webSearchProvider,
                        )
                        ? settings.webSearchProvider
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Provider',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'ddg', child: Text('DuckDuckGo')),
                      DropdownMenuItem(value: 'serper', child: Text('Serper')),
                    ],
                    onChanged: _saving || settings.webSearchProviderManagedExternally
                        ? null
                        : (value) {
                            if (value != null) {
                              unawaited(
                                _update({'web_search_provider': value}),
                              );
                            }
                          },
                  ),
                  if (settings.webSearchProvider == 'serper') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _serperKeyController,
                      onChanged: (_) => setState(() {}),
                      obscureText: true,
                      enabled: !_saving && !settings.serperKeyManagedExternally,
                      decoration: InputDecoration(
                        labelText: 'Serper API key',
                        hintText: settings.serperConfigured ? 'Configured — enter a replacement' : 'Enter API key',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (settings.serperConfigured)
                          TextButton(
                            onPressed: _saving || settings.serperKeyManagedExternally
                                ? null
                                : () => _update({'serper_api_key': ''}),
                            child: const Text('Clear key'),
                          ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed:
                              _saving || settings.serperKeyManagedExternally || _serperKeyController.text.trim().isEmpty
                              ? null
                              : () => _update({
                                  'serper_api_key': _serperKeyController.text.trim(),
                                }),
                          child: const Text('Save key'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          SettingsCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Danger zone',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: const Text(
                'Remove this device from your Sanad account.',
              ),
              trailing: OutlinedButton(
                onPressed: () => _confirmDelete(context),
                child: const Text('Remove device'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove device?'),
        content: Text(
          '${widget.device.name} will be removed from your account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      context.read<DeviceCubit>().deleteAgent(widget.device.id);
    }
  }
}

enum AgentRestartMode { safe, force }

class AgentRestartConfirmationDialog extends StatelessWidget {
  const AgentRestartConfirmationDialog({
    super.key,
    required this.deviceName,
  });

  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 40,
        vertical: 24,
      ),
      title: const Text('Restart agent'),
      content: Text(
        'Restart $deviceName? Restart waits for a safe checkpoint. Force restart '
        'may interrupt active work. The connection will drop until the agent '
        'comes back online.',
      ),
      buttonPadding: EdgeInsets.zero,
      actionsOverflowDirection: VerticalDirection.down,
      actions: [
        TextButton(
          key: const Key('dialog_cancel_restart_button'),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('dialog_force_restart_button'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          onPressed: () => Navigator.of(context).pop(AgentRestartMode.force),
          child: const Text('Force restart'),
        ),
        FilledButton(
          key: const Key('dialog_confirm_restart_button'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          onPressed: () => Navigator.of(context).pop(AgentRestartMode.safe),
          child: const Text('Restart'),
        ),
      ],
    );
  }
}

class DeviceNameEditor extends StatelessWidget {
  const DeviceNameEditor({
    super.key,
    required this.device,
    required this.onRename,
  });

  final DeviceConfig device;
  final Future<void> Function(String name) onRename;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            device.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (device.accountDeviceId != null) ...[
          const SizedBox(width: 4),
          IconButton(
            key: const Key('device_name_edit_button'),
            tooltip: 'Rename device',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () {
              unawaited(
                showDialog<void>(
                  context: context,
                  builder: (context) => DeviceRenameDialog(
                    currentName: device.name,
                    onRename: onRename,
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class DeviceRenameDialog extends StatefulWidget {
  const DeviceRenameDialog({
    super.key,
    required this.currentName,
    required this.onRename,
  });

  final String currentName;
  final Future<void> Function(String name) onRename;

  @override
  State<DeviceRenameDialog> createState() => _DeviceRenameDialogState();
}

class _DeviceRenameDialogState extends State<DeviceRenameDialog> {
  late final TextEditingController _controller;
  String? _requestError;
  bool _saving = false;

  String get _name => _controller.text.trim();
  bool get _canSubmit =>
      !_saving && _name.isNotEmpty && _name != widget.currentName.trim() && _name.length <= DeviceConfig.maxNameLength;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.currentName.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _requestError = null;
    });
    try {
      await widget.onRename(_name);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _requestError = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename device'),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const Key('device_name_field'),
          controller: _controller,
          autofocus: true,
          enabled: !_saving,
          maxLength: DeviceConfig.maxNameLength,
          decoration: InputDecoration(
            labelText: 'Device name',
            errorText: _requestError,
          ),
          onChanged: (_) => setState(() => _requestError = null),
          onSubmitted: (_) => unawaited(_submit()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('device_name_rename_button'),
          onPressed: _canSubmit ? () => unawaited(_submit()) : null,
          child: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Rename'),
        ),
      ],
    );
  }
}

class ProvidersPage extends StatefulWidget {
  const ProvidersPage({super.key, required this.device});
  final DeviceConfig device;

  @override
  State<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends State<ProvidersPage> {
  final _settingsClient = getIt<DeviceSettingsClient>();
  DeviceSettingsSnapshot? _settings;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await _settingsClient.load(widget.device);
      if (mounted) setState(() => _settings = value);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _toggleFailover(bool enabled) async {
    try {
      final value = await _settingsClient.update(widget.device, {
        'provider_auto_failover_enabled': enabled,
      });
      if (mounted) setState(() => _settings = value);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return PageFrame(
      title: 'Providers',
      subtitle: 'Models, credentials, and recovery policy for ${widget.device.name}.',
      child: Column(
        children: [
          SettingsCard(
            child: settings == null
                ? (_error == null ? const LinearProgressIndicator() : Text(_error!))
                : SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Provider Auto Failover'),
                    subtitle: const Text(
                      'Allow eligible provider instances to replace a failed provider. Per-provider preferences are preserved while this is off.',
                    ),
                    value: settings.providerAutoFailover.enabled,
                    onChanged: settings.providerAutoFailover.managedExternally ? null : _toggleFailover,
                  ),
          ),
          const SizedBox(height: 16),
          SettingsCard(
            child: ProviderSetupFlow(
              device: widget.device,
              showReadyState: false,
              globalAutoFailoverEnabled: settings?.providerAutoFailover.enabled ?? true,
            ),
          ),
        ],
      ),
    );
  }
}

class SkillsPage extends StatelessWidget {
  const SkillsPage({super.key, required this.device, this.workspace});
  final DeviceConfig device;
  final DeviceWorkspace? workspace;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<DeviceSkillEntry>>(
    future: getIt<DeviceSkillsClient>().list(
      device,
      workspaceId: workspace?.id,
    ),
    builder: (context, snapshot) {
      final title = workspace == null ? 'Skills' : '${workspace!.name} Skills';
      final subtitle = workspace == null
          ? 'User-level skills available on ${device.name}.'
          : 'Workspace and inherited device skills. Workspace skills take precedence when names match.';
      return PageFrame(
        title: title,
        subtitle: subtitle,
        child: snapshot.connectionState != ConnectionState.done
            ? const LinearProgressIndicator()
            : snapshot.hasError
            ? SettingsCard(child: Text(snapshot.error.toString()))
            : SkillList(
                skills: snapshot.data ?? const [],
                workspaceScoped: workspace != null,
              ),
      );
    },
  );
}

class SkillList extends StatelessWidget {
  const SkillList({
    super.key,
    required this.skills,
    required this.workspaceScoped,
  });
  final List<DeviceSkillEntry> skills;
  final bool workspaceScoped;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) {
      return const SettingsCard(child: Text('No skills found.'));
    }
    return Column(
      children: [
        for (final skill in skills) ...[
          SettingsCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                skill.active ? Icons.auto_awesome : Icons.visibility_off_outlined,
              ),
              title: Text(skill.name),
              subtitle: Text(
                skill.description ?? (skill.shadowedBy == null ? 'No description' : 'Shadowed by ${skill.shadowedBy}'),
              ),
              trailing: Chip(
                label: Text(_originLabel(skill.origin, workspaceScoped)),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  String _originLabel(String origin, bool workspaceScoped) {
    final normalized = origin.toLowerCase();
    if (workspaceScoped && normalized.contains('workspace')) return 'Workspace';
    return 'Device';
  }
}

class WorkspacePage extends StatelessWidget {
  const WorkspacePage({
    super.key,
    required this.device,
    required this.workspace,
    required this.onRename,
    required this.onChangePath,
    required this.onRemove,
  });
  final DeviceConfig device;
  final DeviceWorkspace workspace;
  final VoidCallback onRename;
  final VoidCallback? onChangePath;
  final Future<void> Function()? onRemove;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'Workspace: ',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          TextSpan(text: workspace.name),
                        ],
                      ),
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      workspace.path,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(key: Key('workspace_tab_overview'), text: 'Overview'),
                  Tab(key: Key('workspace_tab_mcp_servers'), text: 'MCP Servers'),
                  Tab(key: Key('workspace_tab_skills'), text: 'Skills'),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            children: [
              PageFrame(
                title: 'Workspace Overview',
                subtitle: 'Configuration scope on ${device.name}.',
                child: SettingsCard(
                  child: Column(
                    children: [
                      DetailRow(label: 'Name', value: workspace.name),
                      DetailRow(label: 'Path', value: workspace.path),
                      DetailRow(
                        label: 'Status',
                        value: workspace.isAvailable ? 'Available' : 'Folder missing',
                      ),
                      DetailRow(label: 'Trust', value: workspace.trustState),
                      const Divider(height: 32),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: onRename,
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Rename Workspace'),
                          ),
                          if (onChangePath != null)
                            FilledButton.icon(
                              onPressed: onChangePath,
                              icon: const Icon(
                                Icons.drive_folder_upload_outlined,
                              ),
                              label: const Text('Change Path'),
                            ),
                          WorkspaceRemovalButton(onRemove: onRemove),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              McpServerManagementScreen(
                device: device,
                workspaceId: workspace.id,
                workspaceName: workspace.name,
                embedded: true,
              ),
              SkillsPage(device: device, workspace: workspace),
            ],
          ),
        ),
      ],
    ),
  );
}

class WorkspaceRemovalButton extends StatelessWidget {
  const WorkspaceRemovalButton({super.key, required this.onRemove});

  final Future<void> Function()? onRemove;

  Future<void> _confirmRemoval(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove workspace?'),
        content: const Text(
          'This removes only the workspace record from Sanad. The folder and '
          'its files will not be deleted, and existing conversations will '
          'remain in the database.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_remove_workspace_button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove workspace'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onRemove?.call();
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const Key('remove_workspace_button'),
    onPressed: onRemove == null ? null : () => _confirmRemoval(context),
    style: OutlinedButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.error,
    ),
    icon: const Icon(Icons.delete_outline),
    label: const Text('Remove workspace'),
  );
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

