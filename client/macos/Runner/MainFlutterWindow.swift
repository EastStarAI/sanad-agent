import Cocoa
import FlutterMacOS
import ApplicationServices

class MainFlutterWindow: NSWindow {
    /// Retains the plain-text paste monitor so a second `awakeFromNib` cannot
    /// install a duplicate, which would insert the same text twice, and window
    /// teardown removes it.
    private var pasteKeyMonitor: Any?

    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = frame
        contentViewController = flutterViewController
        
        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: "flutter.window_width")
        let savedHeight = defaults.double(forKey: "flutter.window_height")
        let savedX = defaults.object(forKey: "flutter.window_x") as? Double
        let savedY = defaults.object(forKey: "flutter.window_y") as? Double
        
        let minimumWidth: CGFloat = 450
        let minimumHeight: CGFloat = 600
        let width = max(savedWidth > 0 ? CGFloat(savedWidth) : 1400, minimumWidth)
        let height = max(savedHeight > 0 ? CGFloat(savedHeight) : 900, minimumHeight)
        
        var rect = NSRect(x: windowFrame.origin.x, y: windowFrame.origin.y, width: width, height: height)
        
        if let x = savedX, let y = savedY {
            if let primaryScreen = NSScreen.screens.first {
                let screenHeight = primaryScreen.frame.height
                let cocoaY = screenHeight - height - CGFloat(y)
                rect.origin = CGPoint(x: CGFloat(x), y: cocoaY)
            }
        }
        
        setFrame(rect, display: true)
        self.contentMinSize = NSSize(width: minimumWidth, height: minimumHeight)
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.styleMask.insert(.fullSizeContentView)
        self.isMovableByWindowBackground = true
        self.backgroundColor = NSColor(deviceRed: 30.0/255.0, green: 30.0/255.0, blue: 30.0/255.0, alpha: 1.0)
        
        if savedX == nil || savedY == nil {
            self.center()
        }
        
        // Initial positioning
        DispatchQueue.main.async { [weak self] in
            self?.repositionTrafficLights()
        }

        let channel = FlutterMethodChannel(name: "com.eaststarai.sanad/permissions", binaryMessenger: flutterViewController.engine.binaryMessenger)
        channel.setMethodCallHandler { (call, result) in
             if call.method == "checkAccessibility" {
                 let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
                 let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
                 result(trusted)
             } else if call.method == "requestAccessibility" {
                  let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                  let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
                  if !trusted {
                     let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                     NSWorkspace.shared.open(url)
                  }
                  result(trusted)
             } else {
                 result(FlutterMethodNotImplemented)
             }
        }

        // Text pastes are captured natively so the transcript is read at the
        // key event, before a dictation tool that posted Cmd+V restores the
        // previous pasteboard. Plain text only: a pasteboard that also carries
        // a file or an image stays with Flutter, whose composer routes it to an
        // attachment or a file token.
        let pasteEventChannel = FlutterMethodChannel(name: "com.eaststarai.sanad/pasteEvents", binaryMessenger: flutterViewController.engine.binaryMessenger)
        if let existingMonitor = pasteKeyMonitor {
            NSEvent.removeMonitor(existingMonitor)
        }
        pasteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // This window's own paste only: another window or a native panel
            // (open/save, alert) keeps its own Cmd+V handling.
            guard let window = self, window.isKeyWindow else { return event }
            guard event.keyCode == 9, event.modifierFlags.contains(.command) else { return event }
            // Cmd+Shift+V, Cmd+Option+V, and Cmd+Ctrl+V are not this paste.
            let disallowedModifiers: NSEvent.ModifierFlags = [.shift, .option, .control]
            guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else { return event }
            let pasteboard = NSPasteboard.general
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return event }
            guard !Self.pasteboardCarriesFileOrImage(pasteboard) else { return event }
            pasteEventChannel.invokeMethod("onExternalPaste", arguments: [
                "text": text,
                "timestamp": Date().timeIntervalSince1970,
            ])
            // Suppress the key event: the text is already inserted at the caret.
            return nil
        }

        RegisterGeneratedPlugins(registry: flutterViewController)

        super.awakeFromNib()
    }

    deinit {
        if let monitor = pasteKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// A pasteboard that carries a file URL or an image is not a text paste:
    /// the Flutter composer owns those through its attachment routing.
    private static func pasteboardCarriesFileOrImage(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        let markers: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("public.svg-image"),
            NSPasteboard.PasteboardType("com.microsoft.bmp"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
        ]
        return markers.contains { types.contains($0) }
    }

    private func repositionTrafficLights() {
        let xOffset: CGFloat = 18.0
        let yOffset: CGFloat = 18.0
        
        positionToolbarButton(.closeButton, x: xOffset, y: yOffset)
        positionToolbarButton(.miniaturizeButton, x: xOffset + 24, y: yOffset)
        positionToolbarButton(.zoomButton, x: xOffset + 48, y: yOffset)
        
        // Force layout update: macOS requires a window resize to visually apply traffic light constraints
        let originalFrame = self.frame
        let modifiedFrameSize = CGSize(width: originalFrame.width + 1, height: originalFrame.height + 1)
        self.setFrame(NSRect(origin: originalFrame.origin, size: modifiedFrameSize), display: true)
        self.setFrame(originalFrame, display: true)
    }
    
    private func positionToolbarButton(_ buttonType: NSWindow.ButtonType, x: CGFloat, y: CGFloat) {
        guard let button = self.standardWindowButton(buttonType),
              let superview = button.superview else { return }

        button.translatesAutoresizingMaskIntoConstraints = false

        // Remove existing layout constraints that affect this button
        let oldConstraints = superview.constraints.filter { ($0.firstItem as? NSButton) == button }
        superview.removeConstraints(oldConstraints)

        // Add new absolute constraints mapped from the top-left
        superview.addConstraint(NSLayoutConstraint(
            item: button, attribute: .left, relatedBy: .equal,
            toItem: superview, attribute: .left, multiplier: 1, constant: x
        ))
        
        superview.addConstraint(NSLayoutConstraint(
            item: button, attribute: .top, relatedBy: .equal,
            toItem: superview, attribute: .top, multiplier: 1, constant: y
        ))
    }
}
