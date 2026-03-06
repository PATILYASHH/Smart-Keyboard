# Smart-Keyboard

A custom Android keyboard (`InputMethodService`) whose UI is rendered in Flutter
and whose engine is implemented in Kotlin.  Flutter and Kotlin communicate
through Platform Channels, keeping end-to-end key-commit latency below 50 ms.

## Quick start

```bash
# Build and install (requires Flutter SDK + Android SDK)
flutter pub get
flutter build apk
adb install build/app/outputs/flutter-apk/app-release.apk
```

After installation go to **Settings → Language & Input → Manage keyboards** and
enable *Smart Keyboard*.

## Project layout

| Path | Purpose |
|------|---------|
| `android/app/src/main/kotlin/…` | Kotlin IME service & engine |
| `lib/` | Flutter keyboard UI |
| `lib/platform/keyboard_channel.dart` | Platform Channel abstraction |
| `test/` | Flutter unit tests |
| `android/app/src/test/…` | Kotlin unit tests |
| `ARCHITECTURE.md` | Full design document |

## Architecture overview

See **[ARCHITECTURE.md](ARCHITECTURE.md)** for:
- Full architecture diagram
- Android service structure
- Kotlin service code walkthrough
- Flutter platform channel integration
- Data-flow description
- Performance considerations
