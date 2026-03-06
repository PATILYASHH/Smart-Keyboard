package com.smartkeyboard

import android.view.KeyEvent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * FlutterChannelManager
 *
 * Owns **all** [MethodChannel] communication between the Kotlin IME layer and
 * the Flutter keyboard UI.
 *
 * Channel catalogue
 * -----------------
 * | Channel name                        | Direction        | Purpose                        |
 * |-------------------------------------|------------------|--------------------------------|
 * | `com.smartkeyboard/keyInput`        | Flutter → Kotlin | Key taps from Flutter UI       |
 * | `com.smartkeyboard/suggestions`     | Kotlin → Flutter | Push updated suggestion list   |
 * | `com.smartkeyboard/inputState`      | Kotlin → Flutter | EditorInfo / field metadata    |
 *
 * Performance contract
 * --------------------
 * • [keyInputChannel] handler runs on [Dispatchers.Main] to avoid blocking the
 *   Flutter message loop.  The actual [InputConnection] commit is synchronous
 *   and typically takes < 5 ms.
 * • Suggestion pushes are dispatched through a [SupervisorJob] coroutine scope
 *   so a slow suggestion computation never blocks key input delivery.
 *
 * @param binaryMessenger    Dart-side binary messenger from the [FlutterEngine].
 * @param keyboardEngine     Processes raw characters into [KeyInputResult] actions.
 * @param suggestionManager  Maintains typing context and computes word predictions.
 * @param onCommitText       Callback that writes text to the active [InputConnection].
 * @param onSendKeyEvent     Callback that injects a raw [KeyEvent].
 * @param onDeleteBackward   Callback that deletes the character before the cursor.
 */
class FlutterChannelManager(
    private val binaryMessenger: BinaryMessenger,
    private val keyboardEngine: KeyboardEngine,
    private val suggestionManager: SuggestionManager,
    private val onCommitText: (String) -> Unit,
    private val onSendKeyEvent: (KeyEvent) -> Unit,
    private val onDeleteBackward: () -> Unit,
    private val onDeleteWord: () -> Unit
) {

    // ---------------------------------------------------------------------------
    // Channels
    // ---------------------------------------------------------------------------

    private lateinit var keyInputChannel: MethodChannel
    private lateinit var suggestionsChannel: MethodChannel
    private lateinit var inputStateChannel: MethodChannel

    // Coroutine scope for non-blocking suggestion pushes
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    companion object {
        const val KEY_INPUT_CHANNEL = "com.smartkeyboard/keyInput"
        const val SUGGESTIONS_CHANNEL = "com.smartkeyboard/suggestions"
        const val INPUT_STATE_CHANNEL = "com.smartkeyboard/inputState"

        // Method names – Kotlin → Flutter
        const val METHOD_UPDATE_SUGGESTIONS = "updateSuggestions"
        const val METHOD_INPUT_STARTED = "inputStarted"
        const val METHOD_INPUT_FINISHED = "inputFinished"
        const val METHOD_KEY_PRESS_ACK = "keyPressAck"

        // Method names – Flutter → Kotlin
        const val METHOD_COMMIT_KEY = "commitKey"
        const val METHOD_DELETE_BACKWARD = "deleteBackward"
        const val METHOD_DELETE_WORD = "deleteWord"
        const val METHOD_COMMIT_SUGGESTION = "commitSuggestion"
        const val METHOD_SEND_KEY_CODE = "sendKeyCode"
    }

    // ---------------------------------------------------------------------------
    // Setup / teardown
    // ---------------------------------------------------------------------------

    fun setup() {
        keyInputChannel = MethodChannel(binaryMessenger, KEY_INPUT_CHANNEL)
        suggestionsChannel = MethodChannel(binaryMessenger, SUGGESTIONS_CHANNEL)
        inputStateChannel = MethodChannel(binaryMessenger, INPUT_STATE_CHANNEL)

        keyInputChannel.setMethodCallHandler { call, result ->
            handleKeyInputCall(call, result)
        }
    }

    fun teardown() {
        keyInputChannel.setMethodCallHandler(null)
        scope.cancel()
    }

    // ---------------------------------------------------------------------------
    // Kotlin → Flutter pushes
    // ---------------------------------------------------------------------------

    /**
     * Pushes the current suggestion list to Flutter.
     * Runs in a coroutine so suggestion computation never stalls key delivery.
     */
    fun pushSuggestions(suggestions: List<String>) {
        scope.launch {
            suggestionsChannel.invokeMethod(
                METHOD_UPDATE_SUGGESTIONS,
                mapOf("suggestions" to suggestions)
            )
        }
    }

    /**
     * Notifies Flutter that a new input field has been focused.
     *
     * @param inputType   android.text.InputType bitmask
     * @param fieldId     Unique ID of the focused view
     * @param packageName Package name of the app owning the field
     * @param label       Human-readable label for the field
     * @param hint        Hint text shown in the field
     */
    fun notifyInputStarted(
        inputType: Int,
        fieldId: Int,
        packageName: String,
        label: String,
        hint: String
    ) {
        scope.launch {
            inputStateChannel.invokeMethod(
                METHOD_INPUT_STARTED,
                mapOf(
                    "inputType" to inputType,
                    "fieldId" to fieldId,
                    "packageName" to packageName,
                    "label" to label,
                    "hint" to hint
                )
            )
        }
    }

    /** Notifies Flutter that the input field was dismissed. */
    fun notifyInputFinished() {
        scope.launch {
            inputStateChannel.invokeMethod(METHOD_INPUT_FINISHED, null)
        }
    }

    // ---------------------------------------------------------------------------
    // Flutter → Kotlin handler
    // ---------------------------------------------------------------------------

    private fun handleKeyInputCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_COMMIT_KEY -> {
                val character = call.argument<String>("character") ?: run {
                    result.error("MISSING_ARG", "character is required", null)
                    return
                }
                val modifierArgs = call.argument<List<String>>("modifiers") ?: emptyList()
                val modifiers = modifierArgs.mapNotNull { modifierFromString(it) }.toSet()

                dispatchKeyInput(character, modifiers)

                // Acknowledge the key press and send back the pressed-key payload
                // so Flutter can play key-press animations without waiting for a
                // round-trip to fetch state.
                result.success(
                    keyboardEngine.buildKeyPressPayload(character, modifiers)
                )
            }

            METHOD_DELETE_BACKWARD -> {
                onDeleteBackward()
                suggestionManager.onCharacterAdded("\b").also { pushSuggestions(it) }
                result.success(null)
            }

            METHOD_DELETE_WORD -> {
                onDeleteWord()
                // Reset the current token after a word deletion
                suggestionManager.reset()
                pushSuggestions(emptyList())
                result.success(null)
            }

            METHOD_COMMIT_SUGGESTION -> {
                val word = call.argument<String>("word") ?: run {
                    result.error("MISSING_ARG", "word is required", null)
                    return
                }
                onCommitText(word)
                // After accepting a suggestion add a space and clear token
                onCommitText(" ")
                suggestionManager.reset()
                pushSuggestions(emptyList())
                result.success(null)
            }

            METHOD_SEND_KEY_CODE -> {
                val keyCode = call.argument<Int>("keyCode") ?: run {
                    result.error("MISSING_ARG", "keyCode is required", null)
                    return
                }
                val inputResult = keyboardEngine.processKeyCode(keyCode)
                dispatchInputResult(inputResult)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------

    private fun dispatchKeyInput(character: String, modifiers: Set<Modifier>) {
        val inputResult = keyboardEngine.processCharacter(character)
        dispatchInputResult(inputResult)

        // Update suggestions in background after every key
        val suggestions = suggestionManager.onCharacterAdded(character)
        pushSuggestions(suggestions)
    }

    private fun dispatchInputResult(result: KeyInputResult) {
        when (result) {
            is KeyInputResult.CommitText -> onCommitText(result.text)
            is KeyInputResult.SendKeyEvent -> onSendKeyEvent(result.event)
            is KeyInputResult.DeleteBackward -> onDeleteBackward()
            is KeyInputResult.NoOp -> Unit
        }
    }

    private fun modifierFromString(value: String): Modifier? = when (value) {
        "shift" -> Modifier.SHIFT
        "caps" -> Modifier.CAPS_LOCK
        "alt" -> Modifier.ALT
        "ctrl" -> Modifier.CTRL
        "symbol" -> Modifier.SYMBOL
        else -> null
    }
}
