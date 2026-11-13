package com.eaststarai.sanad

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The push bridge is always attached: it is the channel the Client uses
        // to read its device token and to receive a notification that arrived
        // while the app was alive. A build with no provider module answers that
        // no token exists.
        SanadPushBridge.attach(flutterEngine)
    }
}
