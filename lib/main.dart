import 'package:flutter/material.dart';
import 'keyboard/keyboard_widget.dart';
import 'platform/keyboard_channel.dart';
import 'spell/spell_corrector.dart';

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
    _loadSpellCorrector();
  }

  /// Loads the bundled dictionary and attaches the [SpellCorrector] to the
  /// channel so that offline suggestions are available immediately after
  /// the keyboard is shown for the first time.
  Future<void> _loadSpellCorrector() async {
    final corrector = await SpellCorrector.fromAsset();
    _channel.setSpellCorrector(corrector);
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
      // Follow the host OS theme so the keyboard blends with the surrounding
      // application chrome in both light and dark mode.
      themeMode: ThemeMode.system,
      home: KeyboardWidget(channel: _channel),
    );
  }
}
