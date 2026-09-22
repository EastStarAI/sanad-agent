import Cocoa
import FlutterMacOS
import ApplicationServices

class MainFlutterWindow: NSWindow {
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

        let pasteEventChannel = FlutterMethodChannel(name: "com.eaststarai.sanad/pasteEvents", binaryMessenger: flutterViewController.engine.binaryMessenger)
        let pasteMonitorMask: NSEvent.EventTypeMask = [.keyDown]
        NSEvent.addLocalMonitorForEvents(matching: pasteMonitorMask) { event in
            if event.keyCode == 9 && event.modifierFlags.contains(.command) {
                let pasteboard = NSPasteboard.general
                let items = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) } ?? []
                let clipboardPreview = items.first ?? ""
                pasteEventChannel.invokeMethod("onExternalPaste", arguments: [
                    "text": clipboardPreview,
                    "timestamp": Date().timeIntervalSince1970,
                ])
                // Suppress the original Cmd+V event so Flutter's EditableText does not handle it.
                return nil
            }
            return event
        }

        RegisterGeneratedPlugins(registry: flutterViewController)

        super.awakeFromNib()
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
