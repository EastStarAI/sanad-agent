// The platform interface is the seam `file_selector` calls through; it ships
// with the package but is only a transitive dependency, so it is referenced
// directly here without a pubspec entry.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/workspace_browser_dialog.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/workspace_picker_helper.dart';

/// Records what the helper asks the real `file_selector` platform for, so the
/// test asserts on the boundary the host panel reads instead of on the
/// widget-level `debugOverride` seam the other suites stub out.
class _RecordingFileSelectorPlatform extends FileSelectorPlatform {
  final List<FileDialogOptions> directoryRequests = <FileDialogOptions>[];
  String? pathToReturn;

  @override
  Future<String?> getDirectoryPathWithOptions(FileDialogOptions options) async {
    directoryRequests.add(options);
    return pathToReturn;
  }
}

final _localDevice = DeviceConfig(
  id: 'local-1',
  name: 'This Mac',
  isOnline: true,
  metadata: const {'is_local_reachable': true},
);

final _remoteDevice = DeviceConfig(
  id: 'remote-1',
  name: 'Sanad Agent Remote',
  isOnline: true,
);

/// A device-bound browser that fails loudly if this branch ever calls it.
const _remoteBrowser = WorkspaceBrowserCallbacks(
  loader: _unusedLoader,
);

Future<WorkspaceTreeSnapshot> _unusedLoader({String? path}) =>
    throw UnimplementedError('the remote loader must not run here');

void main() {
  late _RecordingFileSelectorPlatform platform;
  late FileSelectorPlatform originalPlatform;

  setUp(() {
    originalPlatform = FileSelectorPlatform.instance;
    platform = _RecordingFileSelectorPlatform()
      ..pathToReturn = '/Users/agent/Projects/new-app';
    FileSelectorPlatform.instance = platform;
    AppPlatform.overrideIsDesktop = true;
    WorkspacePickerHelper.debugRemoteBrowserPick = null;
    WorkspacePickerHelper.debugOnRemoteDisabled = null;
  });

  tearDown(() {
    FileSelectorPlatform.instance = originalPlatform;
    AppPlatform.overrideIsDesktop = null;
    WorkspacePickerHelper.debugRemoteBrowserPick = null;
    WorkspacePickerHelper.debugOnRemoteDisabled = null;
  });

  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  testWidgets('a local device asks the host panel for folder creation', (
    tester,
  ) async {
    final context = await pumpContext(tester);

    final path = await WorkspacePickerHelper.pickWorkspacePath(
      context: context,
      device: _localDevice,
      confirmButtonText: 'Use This Folder',
    );

    expect(path, '/Users/agent/Projects/new-app');
    expect(platform.directoryRequests, hasLength(1));
    final options = platform.directoryRequests.single;
    expect(options.canCreateDirectories, isTrue);
    expect(options.confirmButtonText, 'Use This Folder');
  });

  testWidgets('a remote device picks in the browser and never opens the panel', (
    tester,
  ) async {
    final context = await pumpContext(tester);
    var browserPicks = 0;
    WorkspacePickerHelper.debugRemoteBrowserPick = (callbacks) async {
      browserPicks++;
      return '/srv/sanad/workspaces/app';
    };

    final path = await WorkspacePickerHelper.pickWorkspacePath(
      context: context,
      device: _remoteDevice,
      confirmButtonText: 'Use This Folder',
      remoteBrowser: _remoteBrowser,
    );

    expect(path, '/srv/sanad/workspaces/app');
    expect(browserPicks, 1);
    expect(platform.directoryRequests, isEmpty);
  });
}
