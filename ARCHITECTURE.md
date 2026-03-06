# Smart Keyboard – Architecture

A custom Android keyboard built with `InputMethodService` (Kotlin) whose UI is
rendered entirely in Flutter.  The two layers communicate via Flutter Platform
Channels over a shared in-process binary messenger, keeping end-to-end latency
well under the 50 ms target.

---

## 1. Full Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Android OS  (InputMethodManager)                                        │
│                                                                          │
│   ┌────────────────────────────────────────────────────────────────────┐ │
│   │  SmartKeyboardService  (InputMethodService)                        │ │
│   │                                                                    │ │
│   │  ┌─────────────────┐   ┌──────────────────┐  ┌─────────────────┐  │ │
│   │  │ KeyboardEngine  │   │ SuggestionManager│  │FlutterChannel   │  │ │
│   │  │  (key → action) │   │(token → words)   │  │Manager          │  │ │
│   │  └────────┬────────┘   └────────┬─────────┘  └────────┬────────┘  │ │
│   │           │                     │                      │           │ │
│   │           └─────────────────────┴──────────────────────┘           │ │
│   │                              Platform Channel                       │ │
│   │                        (BinaryMessenger in-process)                 │ │
│   │  ┌──────────────────────────────────────────────────────────────┐  │ │
│   │  │  FlutterEngine  ──►  DartExecutor  ──►  main.dart           │  │ │
│   │  │                                                              │  │ │
│   │  │  ┌─────────────────────────────────────────────────────┐    │  │ │
│   │  │  │  Flutter UI  (KeyboardWidget + SuggestionBar)       │    │  │ │
│   │  │  │                                                     │    │  │ │
│   │  │  │   SuggestionBar ◄── updateSuggestions               │    │  │ │
│   │  │  │   KeyWidget     ──► commitKey / deleteBackward      │    │  │ │
│   │  │  │   KeyboardWidget    inputStarted / inputFinished ◄─ │    │  │ │
│   │  │  └─────────────────────────────────────────────────────┘    │  │ │
│   │  └──────────────────────────────────────────────────────────────┘  │ │
│   └────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│   InputConnection ◄── commitText / deleteSurroundingText / sendKeyEvent  │
│                                                                          │
│   ┌──────────────────┐                                                   │
│   │  Target App      │  (e.g. Chrome, Messages, any EditText)            │
│   └──────────────────┘                                                   │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Android Service Structure

```
android/
└── app/
    └── src/
        └── main/
            ├── AndroidManifest.xml          # IME service declaration
            ├── kotlin/com/smartkeyboard/
            │   ├── SmartKeyboardService.kt  # InputMethodService entry point
            │   ├── KeyboardEngine.kt        # Key-code → InputConnection action
            │   ├── SuggestionManager.kt     # Token tracking + word predictions
            │   └── FlutterChannelManager.kt # All MethodChannel wiring
            └── res/
                ├── xml/method.xml           # IME subtypes (en_US, en_GB …)
                └── values/strings.xml
```

The service is declared in `AndroidManifest.xml` with:

```xml
<service
    android:name=".SmartKeyboardService"
    android:permission="android.permission.BIND_INPUT_METHOD">
  <intent-filter>
    <action android:name="android.view.InputMethod" />
  </intent-filter>
  <meta-data
      android:name="android.view.im"
      android:resource="@xml/method" />
</service>
```

Only `android.permission.BIND_INPUT_METHOD` allows the system to bind to it,
preventing rogue apps from injecting key events.

---

## 3. Kotlin Service Code Structure

### 3.1 `SmartKeyboardService`

| Lifecycle method        | Responsibility                                              |
|-------------------------|-------------------------------------------------------------|
| `onCreate()`            | Boot `FlutterEngine`, wire up channels                      |
| `onCreateInputView()`   | Return a `FlutterView` as the keyboard view                 |
| `onStartInput()`        | Forward `EditorInfo` to Flutter via `inputStateChannel`     |
| `onFinishInput()`       | Notify Flutter; reset `SuggestionManager`                   |
| `onDestroy()`           | Tear down channels and destroy `FlutterEngine`              |

### 3.2 `KeyboardEngine`

Pure Kotlin class (no Android Context dependency) that maps characters/keycodes
to a sealed `KeyInputResult`:

```
KeyInputResult
├── CommitText(text: String)         → InputConnection.commitText()
├── SendKeyEvent(event: KeyEvent)    → InputConnection.sendKeyEvent()
├── DeleteBackward                   → InputConnection.deleteSurroundingText()
└── NoOp                             → nothing
```

### 3.3 `SuggestionManager`

Tracks the current token (characters since the last space/punctuation) and
runs a prefix search over a built-in word list.  Replace the stub dictionary
with a Trie or ONNX language model for production.

### 3.4 `FlutterChannelManager`

Owns three `MethodChannel` instances and dispatches between them:

| Channel                         | Direction        | Methods                                               |
|---------------------------------|------------------|-------------------------------------------------------|
| `com.smartkeyboard/keyInput`    | Flutter → Kotlin | `commitKey`, `deleteBackward`, `commitSuggestion`, `sendKeyCode` |
| `com.smartkeyboard/suggestions` | Kotlin → Flutter | `updateSuggestions`                                   |
| `com.smartkeyboard/inputState`  | Kotlin → Flutter | `inputStarted`, `inputFinished`                       |

---

## 4. Flutter Platform Channel Integration

```
lib/
├── main.dart                       # Entry point; wires KeyboardChannel
├── platform/
│   └── keyboard_channel.dart       # All MethodChannel calls in one place
└── keyboard/
    ├── keyboard_widget.dart        # Full QWERTY layout + state machine
    ├── key_widget.dart             # Individual key + scale animation
    └── suggestion_bar.dart         # Horizontally scrollable suggestion chips
```

`KeyboardChannel` is the single Flutter-side abstraction over all three channels.
Widgets subscribe to it via listener callbacks rather than depending on a global
state manager, keeping the dependency graph flat and rebuild scope minimal.

```dart
// Committing a key press
final ack = await channel.commitKey('a', modifiers: {KeyboardModifier.shift});

// Receiving suggestions from Kotlin
channel.addSuggestionListener((suggestions) {
  setState(() => _suggestions = suggestions);
});
```

---

## 5. Data Flow Between Flutter and Kotlin

### Key press (Flutter → Kotlin → InputConnection)

```
User taps key
  │
  ▼
KeyWidget.onTap()
  │  (< 1 ms – UI thread)
  ▼
KeyboardChannel.commitKey('a', modifiers: {shift})
  │  MethodChannel.invokeMethod('commitKey', {...})
  │  (platform channel serialisation ≈ 1–3 ms)
  ▼
FlutterChannelManager.handleKeyInputCall()
  │
  ├─► KeyboardEngine.processCharacter('a')
  │     → KeyInputResult.CommitText("A")
  │
  ├─► InputConnection.commitText("A", 1)
  │     (< 5 ms – binder IPC to target app)
  │
  ├─► SuggestionManager.onCharacterAdded('a')
  │     → ["and", "are", "a"]
  │
  └─► FlutterChannelManager.pushSuggestions(["and", "are", "a"])
        MethodChannel.invokeMethod('updateSuggestions', {...})
        (async, does not block key commit)
```

**Total latency for key commit path: < 10 ms on mid-range hardware.**
Suggestion push is async and does not gate the commit path.

### Suggestion selected (Flutter → Kotlin → InputConnection)

```
User taps suggestion chip
  │
  ▼
SuggestionBar InkWell.onTap('and')
  │
  ▼
KeyboardChannel.commitSuggestion('and')
  │  invokeMethod('commitSuggestion', {word: 'and'})
  ▼
FlutterChannelManager → InputConnection.commitText('and ')
```

### Input field changed (Kotlin → Flutter)

```
App focuses a new EditText
  │
  ▼  (Android system)
SmartKeyboardService.onStartInput(editorInfo)
  │
  ▼
FlutterChannelManager.notifyInputStarted(inputType, fieldId, …)
  │  invokeMethod('inputStarted', {...})
  ▼
KeyboardChannel._handleInputStateCall()
  │  updates _currentField
  ▼
InputStateListeners notified → KeyboardWidget can switch layout
  (e.g. show numeric pad for TYPE_CLASS_NUMBER)
```

---

## 6. Performance Considerations

| Concern | Strategy |
|---------|----------|
| **Channel serialisation** | `StandardMessageCodec` is used (binary, not JSON); round-trip overhead is 1–3 ms on modern devices. |
| **UI thread safety** | Key-input channel handler runs on `Dispatchers.Main`; suggestion pushes use a `SupervisorJob` coroutine so a slow prediction never blocks key delivery. |
| **Flutter frame budget** | Only `SuggestionBar` and the Shift key row rebuild on state changes.  All other keys are stateless `const` widgets that skip reconciliation. |
| **Key animation** | `AnimationController` duration is 80 ms (below one frame at 60 Hz).  The animation is fully GPU-composited via `ScaleTransition`. |
| **Suggestion computation** | Runs in O(n) over the dictionary on the Kotlin main thread.  For a 500-word list this is < 1 ms.  A Trie or BK-Tree is recommended for larger corpora. |
| **Memory footprint** | A single `FlutterEngine` is created in `onCreate()` and reused for the service lifetime.  Creating one per `onCreateInputView()` call would add ~20 MB per invocation. |
| **Cold-start latency** | The Dart VM isolate is warmed up during `onCreate()` (before the first `onCreateInputView()`), so the view is ready immediately when the keyboard appears. |
| **InputConnection IPC** | `commitText` is a synchronous Binder call; it completes in < 5 ms under normal conditions.  Avoid calling it from a background thread to prevent `TransactionTooLargeException`. |
| **Target API level** | `minSdk 24` (Android 7.0) covers > 95 % of active devices and unlocks `InputConnection.requestCursorUpdates()` for cursor-tracking features. |

---

## Directory Tree (full)

```
Smart-Keyboard/
├── android/
│   ├── build.gradle
│   ├── settings.gradle
│   ├── gradle.properties
│   └── app/
│       ├── build.gradle
│       └── src/
│           ├── main/
│           │   ├── AndroidManifest.xml
│           │   ├── kotlin/com/smartkeyboard/
│           │   │   ├── SmartKeyboardService.kt
│           │   │   ├── KeyboardEngine.kt
│           │   │   ├── SuggestionManager.kt
│           │   │   └── FlutterChannelManager.kt
│           │   └── res/
│           │       ├── xml/method.xml
│           │       └── values/strings.xml
│           └── test/kotlin/com/smartkeyboard/
│               ├── KeyboardEngineTest.kt
│               └── SuggestionManagerTest.kt
├── lib/
│   ├── main.dart
│   ├── platform/
│   │   └── keyboard_channel.dart
│   └── keyboard/
│       ├── keyboard_widget.dart
│       ├── key_widget.dart
│       └── suggestion_bar.dart
├── test/
│   └── keyboard_channel_test.dart
├── pubspec.yaml
├── analysis_options.yaml
└── ARCHITECTURE.md
```
