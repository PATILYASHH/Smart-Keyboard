package com.smartkeyboard

import android.view.KeyCharacterMap
import android.view.KeyEvent

/**
 * KeyboardEngine
 *
 * Stateless helper that translates raw key codes / characters into the actions
 * that are dispatched to the active [InputConnection].
 *
 * Design principles
 * -----------------
 * • Kept intentionally thin so that all user-visible state lives in Flutter.
 * • Every public method executes synchronously on whichever coroutine/thread
 *   calls it – callers are responsible for dispatching from the correct thread.
 * • No Android framework dependencies beyond [KeyEvent] / [KeyCharacterMap] so
 *   that the class is easy to unit-test without a device.
 */
class KeyboardEngine {

    // ---------------------------------------------------------------------------
    // Key event processing
    // ---------------------------------------------------------------------------

    /**
     * Converts a printable Unicode [character] to a [KeyInputResult] that the
     * service can commit directly to the [InputConnection].
     *
     * For standard printable characters we return [KeyInputResult.CommitText].
     * For control characters (delete, enter, etc.) we return [KeyInputResult.SendKeyEvent].
     */
    fun processCharacter(character: String): KeyInputResult {
        if (character.isEmpty()) return KeyInputResult.NoOp

        return when (character) {
            "\n", "\r" -> KeyInputResult.SendKeyEvent(
                KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)
            )
            "\b" -> KeyInputResult.DeleteBackward
            "\t" -> KeyInputResult.SendKeyEvent(
                KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB)
            )
            else -> KeyInputResult.CommitText(character)
        }
    }

    /**
     * Processes a raw Android [keyCode] (e.g. from a hardware keyboard event)
     * and returns the appropriate [KeyInputResult].
     */
    fun processKeyCode(keyCode: Int): KeyInputResult {
        return when (keyCode) {
            KeyEvent.KEYCODE_DEL -> KeyInputResult.DeleteBackward
            KeyEvent.KEYCODE_ENTER -> KeyInputResult.SendKeyEvent(
                KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)
            )
            KeyEvent.KEYCODE_SPACE -> KeyInputResult.CommitText(" ")
            else -> {
                val charCode = KeyCharacterMap
                    .load(KeyCharacterMap.VIRTUAL_KEYBOARD)
                    .get(keyCode, 0)
                if (charCode != 0) {
                    KeyInputResult.CommitText(charCode.toChar().toString())
                } else {
                    KeyInputResult.SendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
                }
            }
        }
    }

    /**
     * Builds the payload that is sent to Flutter after every key press so the
     * UI can update its highlighted key and trigger animations.
     */
    fun buildKeyPressPayload(character: String, modifiers: Set<Modifier>): Map<String, Any> {
        return mapOf(
            "character" to character,
            "isShift" to modifiers.contains(Modifier.SHIFT),
            "isCaps" to modifiers.contains(Modifier.CAPS_LOCK),
            "isAlt" to modifiers.contains(Modifier.ALT),
            "timestampMs" to System.currentTimeMillis()
        )
    }
}

// ---------------------------------------------------------------------------
// Sealed result type
// ---------------------------------------------------------------------------

/**
 * Discriminated union describing what the service must do with the result of
 * a key-press evaluation.  Keeping this sealed makes exhaustive `when` checks
 * possible in the service layer.
 */
sealed class KeyInputResult {
    /** Commit a printable string to the active input connection. */
    data class CommitText(val text: String) : KeyInputResult()

    /** Inject a raw [KeyEvent] (e.g. Enter, Tab, arrow keys). */
    data class SendKeyEvent(val event: KeyEvent) : KeyInputResult()

    /** Delete the character immediately before the cursor. */
    object DeleteBackward : KeyInputResult()

    /** No action required (e.g. unknown keycode with no character mapping). */
    object NoOp : KeyInputResult()
}

// ---------------------------------------------------------------------------
// Modifier key state
// ---------------------------------------------------------------------------

/**
 * Modifier keys whose state the keyboard tracks and sends to Flutter.
 */
enum class Modifier {
    SHIFT,
    CAPS_LOCK,
    ALT,
    CTRL,
    SYMBOL
}
