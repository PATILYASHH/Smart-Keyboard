import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_keyboard/keyboard/gesture_handler.dart';
import 'package:smart_keyboard/keyboard/key_widget.dart';
import 'package:smart_keyboard/keyboard/keyboard_widget.dart';
import 'package:smart_keyboard/platform/keyboard_channel.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Creates a minimal [MaterialApp] with a dark [ThemeData] that provides the
/// Material 3 [ColorScheme] expected by keyboard widgets.
Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true),
    darkTheme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1A73E8),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    ),
    themeMode: ThemeMode.dark,
    home: Scaffold(body: child),
  );
}

// ---------------------------------------------------------------------------
// GestureHandler tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Set up channel mocks shared by widget tests that create a KeyboardChannel.
  late KeyboardChannel channel;
  final List<MethodCall> keyInputCalls = [];

  setUp(() {
    keyInputCalls.clear();
    channel = KeyboardChannel();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.smartkeyboard/keyInput'),
      (call) async {
        keyInputCalls.add(call);
        if (call.method == 'commitKey') {
          return {
            'character': call.arguments['character'],
            'isShift': false,
            'isCaps': false,
            'isAlt': false,
            'timestampMs': 0,
          };
        }
        return null;
      },
    );

    for (final ch in [
      'com.smartkeyboard/suggestions',
      'com.smartkeyboard/inputState',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }

    channel.initialize();
  });

  tearDown(() {
    channel.dispose();
    for (final ch in [
      'com.smartkeyboard/keyInput',
      'com.smartkeyboard/suggestions',
      'com.smartkeyboard/inputState',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), null);
    }
  });

  // -------------------------------------------------------------------------
  // GestureHandler
  // -------------------------------------------------------------------------

  group('GestureHandler', () {
    testWidgets('renders its child', (tester) async {
      await tester.pumpWidget(
        _wrap(GestureHandler(child: const Text('hello'))),
      );
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('fires onSwipeLeft on left fling', (tester) async {
      bool swiped = false;

      await tester.pumpWidget(
        _wrap(
          GestureHandler(
            onSwipeLeft: () => swiped = true,
            child: const SizedBox(width: 300, height: 50),
          ),
        ),
      );

      // Simulate a fast left swipe.
      await tester.fling(
        find.byType(SizedBox),
        const Offset(-200, 0),
        600, // px/s – above the 300 px/s threshold
      );
      await tester.pumpAndSettle();

      expect(swiped, isTrue);
    });

    testWidgets('does not fire onSwipeLeft on slow left drag', (tester) async {
      bool swiped = false;

      await tester.pumpWidget(
        _wrap(
          GestureHandler(
            onSwipeLeft: () => swiped = true,
            child: const SizedBox(width: 300, height: 50),
          ),
        ),
      );

      // Slow drag – well under the 300 px/s threshold.
      await tester.drag(
        find.byType(SizedBox),
        const Offset(-100, 0),
      );
      await tester.pumpAndSettle();

      expect(swiped, isFalse);
    });

    testWidgets('fires onSwipeRight on right fling', (tester) async {
      bool swiped = false;

      await tester.pumpWidget(
        _wrap(
          GestureHandler(
            onSwipeRight: () => swiped = true,
            child: const SizedBox(width: 300, height: 50),
          ),
        ),
      );

      await tester.fling(
        find.byType(SizedBox),
        const Offset(200, 0),
        600,
      );
      await tester.pumpAndSettle();

      expect(swiped, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // EmojiKeyWidget
  // -------------------------------------------------------------------------

  group('EmojiKeyWidget', () {
    testWidgets('shows inactive emoji when isActive is false', (tester) async {
      await tester.pumpWidget(
        _wrap(
          Row(children: [
            EmojiKeyWidget(isActive: false, onTap: () {}),
          ]),
        ),
      );
      expect(find.text('😊'), findsOneWidget);
    });

    testWidgets('shows active emoji when isActive is true', (tester) async {
      await tester.pumpWidget(
        _wrap(
          Row(children: [
            EmojiKeyWidget(isActive: true, onTap: () {}),
          ]),
        ),
      );
      expect(find.text('🎨'), findsOneWidget);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      bool tapped = false;
      await tester.pumpWidget(
        _wrap(
          Row(children: [
            EmojiKeyWidget(isActive: false, onTap: () => tapped = true),
          ]),
        ),
      );
      await tester.tap(find.byType(EmojiKeyWidget));
      expect(tapped, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // SpacebarKeyWidget
  // -------------------------------------------------------------------------

  group('SpacebarKeyWidget', () {
    testWidgets('shows "space" label', (tester) async {
      await tester.pumpWidget(
        _wrap(
          Row(children: [
            SpacebarKeyWidget(onTap: (_) {}, onSwipeLeft: () {}),
          ]),
        ),
      );
      expect(find.text('space'), findsOneWidget);
    });

    testWidgets('calls onTap with space character when tapped', (tester) async {
      String? committed;
      await tester.pumpWidget(
        _wrap(
          Row(children: [
            SpacebarKeyWidget(
              onTap: (c) => committed = c,
              onSwipeLeft: () {},
            ),
          ]),
        ),
      );
      await tester.tap(find.byType(SpacebarKeyWidget));
      await tester.pumpAndSettle();
      expect(committed, equals(' '));
    });

    testWidgets('fires onSwipeLeft on left fling', (tester) async {
      bool swiped = false;
      await tester.pumpWidget(
        _wrap(
          Row(children: [
            SpacebarKeyWidget(
              onTap: (_) {},
              onSwipeLeft: () => swiped = true,
            ),
          ]),
        ),
      );

      await tester.fling(
        find.byType(SpacebarKeyWidget),
        const Offset(-200, 0),
        600,
      );
      await tester.pumpAndSettle();

      expect(swiped, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // KeyboardWidget – emoji toggle
  // -------------------------------------------------------------------------

  group('KeyboardWidget emoji toggle', () {
    testWidgets('emoji toggle button is present in bottom row', (tester) async {
      await tester.pumpWidget(
        _wrap(KeyboardWidget(channel: channel)),
      );
      await tester.pump();

      // The inactive emoji key shows 😊.
      expect(find.text('😊'), findsOneWidget);
    });

    testWidgets('tapping emoji key shows emoji panel', (tester) async {
      await tester.pumpWidget(
        _wrap(KeyboardWidget(channel: channel)),
      );
      await tester.pump();

      await tester.tap(find.byType(EmojiKeyWidget));
      await tester.pump();

      // Emoji panel renders; the Q key row should disappear.
      expect(find.text('q'), findsNothing);
      // Active emoji key shows 🎨.
      expect(find.text('🎨'), findsOneWidget);
    });

    testWidgets('tapping emoji key again hides emoji panel', (tester) async {
      await tester.pumpWidget(
        _wrap(KeyboardWidget(channel: channel)),
      );
      await tester.pump();

      // Toggle on then off.
      await tester.tap(find.byType(EmojiKeyWidget));
      await tester.pump();
      await tester.tap(find.byType(EmojiKeyWidget));
      await tester.pump();

      // Letter rows should be visible again.
      expect(find.text('q'), findsOneWidget);
      expect(find.text('😊'), findsOneWidget);
    });

    testWidgets('tapping an emoji in the panel commits it via the channel',
        (tester) async {
      await tester.pumpWidget(
        _wrap(KeyboardWidget(channel: channel)),
      );
      await tester.pump();

      // Open emoji panel.
      await tester.tap(find.byType(EmojiKeyWidget));
      await tester.pump();

      // Tap the first emoji in the panel (😀).
      await tester.tap(find.text('😀').first);
      await tester.pumpAndSettle();

      // The emoji should have been committed via the keyInput channel.
      expect(
        keyInputCalls.any(
          (c) =>
              c.method == 'commitKey' && c.arguments['character'] == '😀',
        ),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // KeyboardWidget – delete word via spacebar swipe
  // -------------------------------------------------------------------------

  group('KeyboardWidget delete-word gesture', () {
    testWidgets('swipe left on spacebar invokes deleteWord channel method',
        (tester) async {
      await tester.pumpWidget(
        _wrap(KeyboardWidget(channel: channel)),
      );
      await tester.pump();

      await tester.fling(
        find.byType(SpacebarKeyWidget),
        const Offset(-200, 0),
        600,
      );
      await tester.pumpAndSettle();

      expect(keyInputCalls.any((c) => c.method == 'deleteWord'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // KeyboardWidget – adaptive key height
  // -------------------------------------------------------------------------

  group('KeyboardWidget adaptive height', () {
    testWidgets('keys render without overflow on a small screen', (tester) async {
      // Simulate a compact portrait screen (320 × 568).
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _wrap(KeyboardWidget(channel: channel)),
      );
      await tester.pump();

      // Verify the widget renders without a RenderFlex overflow error.
      expect(tester.takeException(), isNull);
    });

    testWidgets('keys render without overflow on a large tablet screen',
        (tester) async {
      // Simulate a tablet landscape screen (1024 × 768).
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _wrap(KeyboardWidget(channel: channel)),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
