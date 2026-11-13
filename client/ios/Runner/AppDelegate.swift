import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    /// With the UIScene life cycle the `FlutterViewController` comes from the
    /// storyboard and the engine is created implicitly, so plugins have to be
    /// registered on the engine bridge instead of on the app delegate.
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        // The push bridge is registered after the plugins so the per-event
        // foreground hook can preserve whatever notification delegate they
        // installed.
        if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SanadPushBridge") {
            SanadPushBridge.register(with: registrar)
        }
        SanadPushBridge.installNotificationDelegate()
    }

    /// APNs hands the device token to the application delegate; the bridge
    /// forwards it to Dart, which is the only place that decides what to
    /// register.
    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        SanadPushBridge.handleDeviceToken(deviceToken)
    }

    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        SanadPushBridge.handleRegistrationFailure(error)
    }
}

/// The iOS half of the mobile push boundary.
///
/// The Dart side owns every notification rule; this part only moves bytes between
/// APNs and the Flutter engine, and answers the one question the operating system
/// asks before Dart can be involved: should a remote notification be presented
/// while the app is in the foreground?
///
/// Two facts shape the implementation and are recorded in
/// `docs/technical/mobile_push_delivery.md`:
///
/// - No provider credentials live here. APNs identifies the app by its signing
///   identity and the `aps-environment` entitlement, so nothing secret ships in
///   the bundle and no third-party push SDK is linked.
/// - Foreground presentation is decided per event, never globally. A remote
///   notification for the session already on screen is not presented, because the
///   in-app prompt is the surface for it; any other session is presented as a
///   banner with sound and its category actions.
final class SanadPushBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
    static let methodChannelName = "com.eaststarai.sanad/mobilePush"
    static let eventChannelName = "com.eaststarai.sanad/mobilePushEvents"

    /// The canonical envelope key the Dart parser reads.
    static let envelopeKey = "sanad_envelope"

    /// One shared instance: the delegate callbacks and the plugin share state.
    private static var shared: SanadPushBridge?
    private static var notificationDelegate: SanadNotificationDelegate?

    private var eventSink: FlutterEventSink?
    private var pendingMessages: [[String: Any]] = []
    private var pendingLaunch: [String: Any]?
    private var visibleSessionId: String?
    private var deviceToken: String?

    static func register(with registrar: FlutterPluginRegistrar) {
        let bridge = shared ?? SanadPushBridge()
        shared = bridge

        let methods = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(bridge, channel: methods)

        let events = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger()
        )
        events.setStreamHandler(bridge)
    }

    // MARK: - FlutterPlugin

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "currentToken":
            result(tokenPayload())
        case "ensureRegistration":
            // Registering for remote notifications is what obtains the APNs
            // token. It does not ask the user for permission: that stays an
            // explicit Settings action.
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
            result(nil)
        case "takeInitialMessage":
            let launch = pendingLaunch
            pendingLaunch = nil
            result(launch)
        case "setVisibleSession":
            let arguments = call.arguments as? [String: Any]
            let sessionId = arguments?["session_id"] as? String
            visibleSessionId = (sessionId?.isEmpty ?? true) ? nil : sessionId
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        for message in pendingMessages {
            events(message)
        }
        pendingMessages.removeAll()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Native entry points

    /// Installs the per-event foreground decision.
    ///
    /// The existing chain is preserved: whatever the engine or another plugin had
    /// installed keeps receiving the callbacks for the notifications it owns, so
    /// taking over the delegate cannot silence local notifications.
    static func installNotificationDelegate() {
        let center = UNUserNotificationCenter.current()
        guard !(center.delegate is SanadNotificationDelegate) else { return }
        let delegate = SanadNotificationDelegate(previous: center.delegate)
        notificationDelegate = delegate
        center.delegate = delegate
    }

    static func handleDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        shared?.deviceToken = token
        shared?.emit([
            "type": "token",
            "value": token,
            "provider": "apns"
        ])
    }

    static func handleRegistrationFailure(_ error: Error) {
        // Diagnostic only: there is no token to register, and the Dart side
        // keeps reporting that no token exists.
        NSLog("Sanad push registration failed: %@", error.localizedDescription)
    }

    /// The presentation options for one foreground delivery.
    ///
    /// Only the exact session on screen is silent; every other arrival is a
    /// heads-up banner, so the user is neither interrupted by the prompt already
    /// in front of them nor missed anywhere else.
    static func foregroundOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        guard notification.request.trigger is UNPushNotificationTrigger else { return [] }
        let sessionId = sessionIdentifier(in: notification.request.content.userInfo)
        if let visible = shared?.visibleSessionId, !visible.isEmpty, sessionId == visible {
            return []
        }
        return [.banner, .sound, .list]
    }

    /// Records the interaction and tells Dart which action was pressed.
    static func handleResponse(_ response: UNNotificationResponse) {
        guard response.notification.request.trigger is UNPushNotificationTrigger else { return }
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        var data = flatten(response.notification.request.content.userInfo)
        data["type"] = "interaction"
        // The default action means "the user opened the notification"; anything
        // else is the action the registered category offered.
        data["action_id"] = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? "open"
            : response.actionIdentifier
        shared?.deliver(data)
    }

    private static func sessionIdentifier(in userInfo: [AnyHashable: Any]) -> String? {
        if let sessionId = userInfo["session_id"] as? String, !sessionId.isEmpty {
            return sessionId
        }
        guard
            let raw = userInfo[envelopeKey] as? String,
            let data = raw.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = envelope["session_id"] as? String,
            !sessionId.isEmpty
        else { return nil }
        return sessionId
    }

    private static func flatten(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var flat: [String: String] = [:]
        for (key, value) in userInfo {
            guard let name = key as? String else { continue }
            switch value {
            case let text as String:
                flat[name] = text
            case let number as NSNumber:
                flat[name] = number.stringValue
            default:
                flat[name] = String(describing: value)
            }
        }
        return flat
    }

    private func tokenPayload() -> [String: Any] {
        guard let token = deviceToken, !token.isEmpty else {
            return ["value": "", "provider": "apns"]
        }
        return ["value": token, "provider": "apns"]
    }

    /// A launch interaction arrives before Dart subscribes, so it is held for
    /// `takeInitialMessage` and never also queued on the event stream; a message
    /// that is delivered twice would authorize the same decision twice.
    private func deliver(_ message: [String: Any]) {
        if let sink = eventSink {
            sink(message)
            return
        }
        pendingLaunch = message
    }

    private func emit(_ message: [String: Any]) {
        if let sink = eventSink {
            sink(message)
            return
        }
        pendingMessages.append(message)
    }
}

/// Routes notification-center callbacks without hiding the existing chain.
final class SanadNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    init(previous: UNUserNotificationCenterDelegate?) {
        self.previous = previous
        self.fallback = UIApplication.shared.delegate as? UNUserNotificationCenterDelegate
    }

    private weak var previous: UNUserNotificationCenterDelegate?
    private weak var fallback: UNUserNotificationCenterDelegate?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.trigger is UNPushNotificationTrigger {
            completionHandler(SanadPushBridge.foregroundOptions(for: notification))
            return
        }
        // Everything else keeps the behavior it had before this delegate existed.
        if let previous = previous {
            previous.userNotificationCenter?(
                center,
                willPresent: notification,
                withCompletionHandler: completionHandler
            )
            return
        }
        if let fallback = fallback {
            fallback.userNotificationCenter?(
                center,
                willPresent: notification,
                withCompletionHandler: completionHandler
            )
            return
        }
        completionHandler([])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.trigger is UNPushNotificationTrigger {
            SanadPushBridge.handleResponse(response)
            completionHandler()
            return
        }
        if let previous = previous {
            previous.userNotificationCenter?(
                center,
                didReceive: response,
                withCompletionHandler: completionHandler
            )
            return
        }
        if let fallback = fallback {
            fallback.userNotificationCenter?(
                center,
                didReceive: response,
                withCompletionHandler: completionHandler
            )
            return
        }
        completionHandler()
    }
}
