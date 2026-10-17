import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    /// The Client owns background operation: closing the window hides it and keeps
    /// sockets, the local Agent connection, and the Client CLI endpoint alive, so
    /// the tray `Quit` item (or Cmd+Q) is the only path that terminates the app.
    /// Flutter's template answers `true` here, which makes AppKit terminate the
    /// process as soon as the last window closes and silently discards the tray
    /// icon on macOS only.
    override func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return false
    }

    /// A Dock-icon click, Finder open, or Spotlight launch of an already running
    /// app arrives as a reopen request. Flutter's delegate implements no reopen
    /// handling and AppKit never un-hides a window that was ordered out, so the
    /// Client forwards the request to its Dart window owner, which already knows
    /// how to show the window (same path as the tray `Show` item).
    override func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag, let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(
                name: "com.eaststarai.sanad/windowLifecycle",
                binaryMessenger: controller.engine.binaryMessenger
            )
            channel.invokeMethod("reopenRequested", arguments: nil)
        }
        return true
    }

    override func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        return true
    }
}
