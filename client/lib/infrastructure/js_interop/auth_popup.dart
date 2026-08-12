// JavaScript interop for Web popup authentication
// This file contains the bridge between Dart and browser JavaScript

@JS('AuthPopup')
library auth_popup;

import 'dart:js_interop';

/// Opens a popup window for OAuth authentication
/// Returns the window reference
@JS('openPopup')
external JSObject? openPopup(
  String url,
  String windowName,
  String windowFeatures,
);

/// Registers a message event listener for the popup
@JS('isPopupClosed')
external bool isPopupClosed();

/// Closes the popup window if it exists
@JS('closePopup')
external void closePopup();

@JS('takeAuthorizationMessage')
external JSString? takeAuthorizationMessage();

@JS('appOrigin')
external JSString appOrigin();
