package com.smartkeyboard

import io.flutter.embedding.android.FlutterActivity

/**
 * Main entry-point activity for the Smart Keyboard app.
 *
 * Hosts the Flutter UI (keyboard settings / onboarding screen defined in
 * `lib/main.dart`) and acts as the launcher activity so users can open the
 * app from the home screen after installing.  The actual keyboard functionality
 * runs inside [SmartKeyboardService] which is bound by the system IME framework.
 */
class MainActivity : FlutterActivity()
