package com.eaststarai.sanad

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of the mobile push boundary.
 *
 * The Dart side owns every notification rule; this class only moves bytes between
 * a push provider and the Flutter engine, and holds the two facts the engine needs
 * before Dart can be involved: the device token and the message that launched the
 * process.
 *
 * The provider SDK is deliberately absent from this module. Adding one would ship
 * a provider dependency and its build configuration in the public repository,
 * which the release contract forbids; the provider module that the platform owner
 * builds calls [onToken], [onDisplay], and [onInteraction] from its own service.
 * Without it this bridge answers "no token" and the Client simply never registers
 * a device, which is the honest state for a build that cannot receive a push.
 */
class SanadPushBridge private constructor() :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        const val methodChannelName = "com.eaststarai.sanad/mobilePush"
        const val eventChannelName = "com.eaststarai.sanad/mobilePushEvents"

        private var instance: SanadPushBridge? = null

        /** Registers the bridge on [engine]; called once per process. */
        fun attach(engine: FlutterEngine) {
            if (instance != null) return
            val bridge = SanadPushBridge()
            instance = bridge
            val messenger = engine.dartExecutor.binaryMessenger
            MethodChannel(messenger, methodChannelName).setMethodCallHandler(bridge)
            EventChannel(messenger, eventChannelName).setStreamHandler(bridge)
        }

        /**
         * Publishes a provider token. Called by the platform provider module, and
         * never persisted or logged here.
         */
        fun onToken(token: String, provider: String = "fcm") {
            val bridge = instance ?: return
            bridge.deviceToken = token
            bridge.emit(
                mapOf(
                    "type" to "token",
                    "value" to token,
                    "provider" to provider,
                )
            )
        }

        /** Publishes a notification that arrived while the process was alive. */
        fun onDisplay(data: Map<String, String>) {
            instance?.emit(data + mapOf("type" to "message"))
        }

        /**
         * Publishes an interaction with a notification the system presented,
         * including one that started the process.
         *
         * A launch interaction is held for `takeInitialMessage` and never also
         * queued on the event stream: delivering it twice would authorize the
         * same decision twice.
         */
        fun onInteraction(data: Map<String, String>, actionId: String) {
            val bridge = instance ?: return
            val message = data + mapOf("type" to "interaction", "action_id" to actionId)
            if (bridge.events == null) {
                bridge.pendingLaunch = message
                return
            }
            bridge.emit(message)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var deviceToken: String? = null
    private var pendingLaunch: Map<String, String>? = null
    private val pendingMessages = mutableListOf<Map<String, String>>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "currentToken" -> result.success(
                mapOf(
                    "value" to (deviceToken ?: ""),
                    "provider" to "fcm",
                )
            )

            "ensureRegistration" -> {
                // Nothing to start here: the provider module owns registration.
                // A build without one never issues a token, and the Client then
                // reports that no device is registered instead of pretending.
                result.success(null)
            }

            "takeInitialMessage" -> {
                val launch = pendingLaunch
                pendingLaunch = null
                result.success(launch)
            }

            "setVisibleSession" -> {
                // Android decides foreground presentation in Dart; the mirror is
                // accepted so both platforms answer the same channel contract.
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        events = eventSink
        val pending = pendingMessages.toList()
        pendingMessages.clear()
        for (message in pending) {
            emit(message)
        }
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun emit(message: Map<String, String>) {
        mainHandler.post {
            val sink = events
            if (sink == null) {
                pendingMessages.add(message)
                return@post
            }
            sink.success(message)
        }
    }
}
