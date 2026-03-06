import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_keyboard/platform/keyboard_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KeyboardChannel channel;

  // Capture outgoing method calls on the key input channel
  final List<MethodCall> keyInputCalls = [];

  setUp(() {
    keyInputCalls.clear();
    channel = KeyboardChannel();

    // Mock the key-input channel: record calls and return a canned ack payload.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.smartkeyboard/keyInput'),
      (MethodCall call) async {
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

    // Mock the suggestions and inputState channels (no-op)
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.smartkeyboard/suggestions'),
      (_) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.smartkeyboard/inputState'),
      (_) async => null,
    );

    channel.initialize();
  });

  tearDown(() {
    channel.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.smartkeyboard/keyInput'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.smartkeyboard/suggestions'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.smartkeyboard/inputState'),
      null,
    );
  });

  // ---------------------------------------------------------------------------
  // commitKey
  // ---------------------------------------------------------------------------

  test('commitKey sends correct character over keyInput channel', () async {
    await channel.commitKey('a');

    expect(keyInputCalls, hasLength(1));
    expect(keyInputCalls.first.method, equals('commitKey'));
    expect(keyInputCalls.first.arguments['character'], equals('a'));
  });

  test('commitKey includes modifier names in arguments', () async {
    await channel.commitKey(
      'A',
      modifiers: {KeyboardModifier.shift},
    );

    final args =
        keyInputCalls.first.arguments as Map<Object?, Object?>;
    expect(args['modifiers'], contains('shift'));
  });

  // ---------------------------------------------------------------------------
  // deleteBackward
  // ---------------------------------------------------------------------------

  test('deleteBackward invokes deleteBackward method', () async {
    await channel.deleteBackward();

    expect(keyInputCalls, hasLength(1));
    expect(keyInputCalls.first.method, equals('deleteBackward'));
  });

  test('deleteWord invokes deleteWord method', () async {
    await channel.deleteWord();

    expect(keyInputCalls, hasLength(1));
    expect(keyInputCalls.first.method, equals('deleteWord'));
  });

  // ---------------------------------------------------------------------------
  // commitSuggestion
  // ---------------------------------------------------------------------------

  test('commitSuggestion sends word argument', () async {
    await channel.commitSuggestion('hello');

    expect(keyInputCalls, hasLength(1));
    expect(keyInputCalls.first.method, equals('commitSuggestion'));
    expect(keyInputCalls.first.arguments['word'], equals('hello'));
  });

  // ---------------------------------------------------------------------------
  // Modifier toggle
  // ---------------------------------------------------------------------------

  test('toggleModifier adds modifier to activeModifiers', () {
    expect(channel.activeModifiers, isEmpty);
    channel.toggleModifier(KeyboardModifier.shift);
    expect(channel.activeModifiers, contains(KeyboardModifier.shift));
  });

  test('toggleModifier removes already-active modifier', () {
    channel.toggleModifier(KeyboardModifier.shift);
    channel.toggleModifier(KeyboardModifier.shift);
    expect(channel.activeModifiers, isNot(contains(KeyboardModifier.shift)));
  });

  test('toggleModifier notifies listeners', () {
    Set<KeyboardModifier>? notified;
    channel.addModifierListener((mods) => notified = mods);

    channel.toggleModifier(KeyboardModifier.capsLock);

    expect(notified, contains(KeyboardModifier.capsLock));
  });

  // ---------------------------------------------------------------------------
  // Suggestion updates (Kotlin → Flutter)
  // ---------------------------------------------------------------------------

  test('suggestion listener is called when updateSuggestions is received',
      () async {
    List<String>? received;
    channel.addSuggestionListener((s) => received = s);

    // Simulate Kotlin pushing a suggestion update
    const codec = StandardMethodCodec();
    final ByteData data = codec.encodeMethodCall(
      const MethodCall(
        'updateSuggestions',
        {'suggestions': ['hello', 'help', 'here']},
      ),
    );

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.smartkeyboard/suggestions',
      data,
      (_) {},
    );

    expect(received, equals(['hello', 'help', 'here']));
  });

  test('suggestions getter reflects latest update', () async {
    const codec = StandardMethodCodec();
    final ByteData data = codec.encodeMethodCall(
      const MethodCall(
        'updateSuggestions',
        {'suggestions': ['world', 'work']},
      ),
    );

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.smartkeyboard/suggestions',
      data,
      (_) {},
    );

    expect(channel.suggestions, equals(['world', 'work']));
  });

  // ---------------------------------------------------------------------------
  // Input state (Kotlin → Flutter)
  // ---------------------------------------------------------------------------

  test('inputStarted populates currentField', () async {
    const codec = StandardMethodCodec();
    final ByteData data = codec.encodeMethodCall(
      const MethodCall('inputStarted', {
        'inputType': 1,
        'fieldId': 42,
        'packageName': 'com.example',
        'label': 'Username',
        'hint': 'Enter username',
      }),
    );

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.smartkeyboard/inputState',
      data,
      (_) {},
    );

    expect(channel.currentField, isNotNull);
    expect(channel.currentField!.fieldId, equals(42));
    expect(channel.currentField!.packageName, equals('com.example'));
  });

  test('inputFinished clears currentField and suggestions', () async {
    const codec = StandardMethodCodec();

    // First start an input field
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.smartkeyboard/inputState',
      codec.encodeMethodCall(const MethodCall('inputStarted', {
        'inputType': 1,
        'fieldId': 1,
        'packageName': '',
        'label': '',
        'hint': '',
      })),
      (_) {},
    );

    // Then finish it
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.smartkeyboard/inputState',
      codec.encodeMethodCall(const MethodCall('inputFinished', null)),
      (_) {},
    );

    expect(channel.currentField, isNull);
    expect(channel.suggestions, isEmpty);
  });
}
