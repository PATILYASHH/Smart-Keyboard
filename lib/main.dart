import 'package:flutter/material.dart';
import 'keyboard/keyboard_widget.dart';
import 'platform/keyboard_channel.dart';

/// Entry point for the Flutter keyboard UI.
///
/// The [main] function is called by the Flutter engine embedded inside the
/// Android [SmartKeyboardService].  We call [runApp] with [KeyboardApp] which
/// wires up the [KeyboardChannel] and renders the [KeyboardWidget].
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KeyboardApp());
}

/// Root widget of the keyboard application.
///
/// Uses a [ChangeNotifierProvider]-style pattern through [KeyboardChannel] to
/// propagate state (suggestions, input metadata, modifier keys) down the widget
/// tree without rebuilding the entire tree on every keystroke.
class KeyboardApp extends StatefulWidget {
  const KeyboardApp({super.key});

  @override
  State<KeyboardApp> createState() => _KeyboardAppState();
}

class _KeyboardAppState extends State<KeyboardApp> {
  late final KeyboardChannel _channel;

  @override
  void initState() {
    super.initState();
    _channel = KeyboardChannel();
    _channel.initialize();
  }

  @override
  void dispose() {
    _channel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Remove status-bar padding – the keyboard sits inside the IME window.
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8)),
        useMaterial3: true,
      ),
      // Dark theme: required by the "Dark mode UI" specification.
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // Always use the dark theme — the keyboard runs inside an IME window
      // where the host OS controls the surrounding UI chrome; forcing dark mode
      // provides a consistent, battery-friendly appearance on OLED displays.
      themeMode: ThemeMode.dark,
      home: KeyboardWidget(channel: _channel),
    );
  }
}
