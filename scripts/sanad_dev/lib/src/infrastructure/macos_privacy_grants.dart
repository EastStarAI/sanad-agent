import 'dart:ffi';
import 'dart:io';

/// Result of a passive macOS privacy preflight.
///
/// These probes answer a question without asking the operating system for
/// anything: they never open a consent dialog, never capture the screen, never
/// drive another application, and never change system state.
enum MacOsPrivacyPreflight { granted, denied, unavailable }

/// Injected reader for a passive preflight, used by tests.
typedef MacOsPrivacyPreflightReader = MacOsPrivacyPreflight Function();

/// Frameworks that export the preflight APIs used below.
///
/// Only preflight symbols are looked up: `AXIsProcessTrusted()` (Application
/// Services) and `CGPreflightScreenCaptureAccess()` (Core Graphics). The
/// requesting counterparts (`AXIsProcessTrustedWithOptions` with a prompt
/// option and `CGRequestScreenCaptureAccess`) are deliberately never called.
const macOsApplicationServicesLibrary =
    '/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices';
const macOsCoreGraphicsLibrary =
    '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics';

/// Accessibility grant for this process, read passively.
MacOsPrivacyPreflight preflightAccessibilityTrust() =>
    _callPreflight(macOsApplicationServicesLibrary, 'AXIsProcessTrusted');

/// Screen Recording grant for this process, read passively.
MacOsPrivacyPreflight preflightScreenCaptureAccess() =>
    _callPreflight(macOsCoreGraphicsLibrary, 'CGPreflightScreenCaptureAccess');

MacOsPrivacyPreflight _callPreflight(String libraryPath, String symbol) {
  if (!Platform.isMacOS) return MacOsPrivacyPreflight.unavailable;
  try {
    final library = DynamicLibrary.open(libraryPath);
    final preflight = library
        .lookupFunction<Bool Function(), bool Function()>(symbol);
    return preflight()
        ? MacOsPrivacyPreflight.granted
        : MacOsPrivacyPreflight.denied;
  } on Object {
    // A missing framework or symbol (an older OS) is reported as unknown rather
    // than as a missing grant, so `doctor` never claims a grant is absent when
    // it simply could not be read passively.
    return MacOsPrivacyPreflight.unavailable;
  }
}
