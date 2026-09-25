import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/infrastructure/platform/desktop_lifecycle_manager.dart';

class FakeDesktopWindowManagerAdapter implements DesktopWindowManagerAdapter {
  int hideCalls = 0;
  int showCalls = 0;
  int focusCalls = 0;
  bool? preventClose;
  int destroyCalls = 0;

  @override
  Future<void> hide() async {
    hideCalls++;
  }

  @override
  Future<void> show() async {
    showCalls++;
  }

  @override
  Future<void> focus() async {
    focusCalls++;
  }

  @override
  Future<void> setPreventClose(bool prevent) async {
    preventClose = prevent;
  }

  @override
  Future<void> destroy() async {
    destroyCalls++;
  }
}

void main() {
  group('DesktopLifecycleManager', () {
    late FakeDesktopWindowManagerAdapter windowAdapter;

    setUp(() {
      windowAdapter = FakeDesktopWindowManagerAdapter();
    });

    test('hideWindow hides the window and sets isWindowHidden flag', () async {
      final manager = DesktopLifecycleManager(windowAdapter: windowAdapter);

      expect(manager.isWindowHidden, isFalse);
      await manager.hideWindow();
      expect(manager.isWindowHidden, isTrue);
      expect(windowAdapter.hideCalls, equals(1));
    });

    test('showWindow restores and focuses the window and clears isWindowHidden flag', () async {
      final manager = DesktopLifecycleManager(windowAdapter: windowAdapter);

      await manager.hideWindow();
      expect(manager.isWindowHidden, isTrue);

      await manager.showWindow();
      expect(manager.isWindowHidden, isFalse);
      expect(windowAdapter.showCalls, equals(1));
      expect(windowAdapter.focusCalls, equals(1));
    });

    test('handleWindowClose on macOS/Windows hides window without quitting or disposing', () async {
      bool trayDisposed = false;
      bool cliStopped = false;

      final manager = DesktopLifecycleManager(
        windowAdapter: windowAdapter,
        onDisposeTray: () async => trayDisposed = true,
        onStopCliHost: () async => cliStopped = true,
      );

      await manager.handleWindowClose(isLinux: false);

      expect(windowAdapter.hideCalls, equals(1));
      expect(windowAdapter.destroyCalls, equals(0));
      expect(manager.isQuitting, isFalse);
      expect(trayDisposed, isFalse);
      expect(cliStopped, isFalse);
    });

    test('handleWindowClose on Linux performs explicit quit', () async {
      bool trayDisposed = false;
      bool exitCalled = false;

      final manager = DesktopLifecycleManager(
        windowAdapter: windowAdapter,
        onDisposeTray: () async => trayDisposed = true,
        onExitProcess: () => exitCalled = true,
      );

      await manager.handleWindowClose(isLinux: true);

      expect(manager.isQuitting, isTrue);
      expect(trayDisposed, isTrue);
      expect(windowAdapter.preventClose, isFalse);
      expect(windowAdapter.destroyCalls, equals(1));
      expect(exitCalled, isTrue);
    });

    test('quit executes all cleanup steps in deterministic order', () async {
      final steps = <String>[];

      final manager = DesktopLifecycleManager(
        windowAdapter: windowAdapter,
        onDisposeTray: () async => steps.add('disposeTray'),
        onStopCliHost: () async => steps.add('stopCliHost'),
        onFlushCache: () async => steps.add('flushCache'),
        onDisposeAppState: () => steps.add('disposeAppState'),
        onExitProcess: () => steps.add('exitProcess'),
      );

      await manager.quit();

      expect(steps, equals([
        'disposeTray',
        'stopCliHost',
        'flushCache',
        'disposeAppState',
        'exitProcess',
      ]));
      expect(windowAdapter.preventClose, isFalse);
      expect(windowAdapter.destroyCalls, equals(1));
      expect(manager.isQuitting, isTrue);
    });

    test('quit is idempotent and runs cleanup only once', () async {
      int disposeTrayCalls = 0;

      final manager = DesktopLifecycleManager(
        windowAdapter: windowAdapter,
        onDisposeTray: () async => disposeTrayCalls++,
      );

      await manager.quit();
      await manager.quit();

      expect(disposeTrayCalls, equals(1));
      expect(windowAdapter.destroyCalls, equals(1));
    });

    test('quit continues cleanup even if individual steps throw', () async {
      bool cliStopped = false;
      bool cacheFlushed = false;
      bool exitCalled = false;

      final manager = DesktopLifecycleManager(
        windowAdapter: windowAdapter,
        onDisposeTray: () async => throw Exception('Tray destroy failed'),
        onStopCliHost: () async => cliStopped = true,
        onFlushCache: () async => cacheFlushed = true,
        onDisposeAppState: () => throw Exception('AppState error'),
        onExitProcess: () => exitCalled = true,
      );

      await manager.quit();

      expect(cliStopped, isTrue);
      expect(cacheFlushed, isTrue);
      expect(windowAdapter.destroyCalls, equals(1));
      expect(exitCalled, isTrue);
    });
  });
}
