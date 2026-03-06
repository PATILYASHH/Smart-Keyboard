package com.smartkeyboard

import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * SmartKeyboardService
 *
 * The central Android [InputMethodService] that bridges the system IME lifecycle with the Flutter
 * UI and the Kotlin keyboard engine.
 *
 * Lifecycle:
 *  1. [onCreate]       – Boot Flutter engine, set up platform channels.
 *  2. [onCreateInputView] – Inflate the Flutter-based keyboard view.
 *  3. [onStartInput]   – Notify Flutter of new input target (EditorInfo).
 *  4. [onFinishInput]  – Notify Flutter that the input field was dismissed.
 *  5. [onDestroy]      – Clean up engine resources.
 *
 * All text commits and cursor movements happen through [KeyboardEngine], which forwards
 * decisions back through [InputConnection] so latency stays below 50 ms.
 */
class SmartKeyboardService : InputMethodService() {

    private lateinit var flutterEngine: FlutterEngine
    private lateinit var flutterView: FlutterView
    private lateinit var channelManager: FlutterChannelManager
    private lateinit var keyboardEngine: KeyboardEngine
    private lateinit var suggestionManager: SuggestionManager

    // ---------------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()

        flutterEngine = FlutterEngine(this).apply {
            dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
        }

        keyboardEngine = KeyboardEngine()
        suggestionManager = SuggestionManager()

        channelManager = FlutterChannelManager(
            binaryMessenger = flutterEngine.dartExecutor.binaryMessenger,
            keyboardEngine = keyboardEngine,
            suggestionManager = suggestionManager,
            onCommitText = { text -> currentInputConnection?.commitText(text, 1) },
            onSendKeyEvent = { keyCode -> currentInputConnection?.sendKeyEvent(keyCode) },
            onDeleteBackward = { currentInputConnection?.deleteSurroundingText(1, 0) },
            onDeleteWord = { deleteWordBeforeCursor() }
        )

        channelManager.setup()
    }

    /**
     * Called by the system when it needs the keyboard view.
     * We return a [FlutterView] that renders the full Dart/Flutter UI.
     */
    override fun onCreateInputView(): View {
        flutterView = FlutterView(this)
        flutterView.attachToFlutterEngine(flutterEngine)
        return flutterView
    }

    /**
     * Called every time an input field gains focus.
     * Sends [EditorInfo] metadata to Flutter so it can adapt the layout
     * (e.g. show a numeric pad for TYPE_CLASS_NUMBER).
     */
    override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        channelManager.notifyInputStarted(
            inputType = attribute.inputType,
            fieldId = attribute.fieldId,
            packageName = attribute.packageName ?: "",
            label = attribute.label?.toString() ?: "",
            hint = attribute.hintText?.toString() ?: ""
        )
    }

    override fun onFinishInput() {
        super.onFinishInput()
        channelManager.notifyInputFinished()
        suggestionManager.reset()
    }

    override fun onDestroy() {
        channelManager.teardown()
        flutterView.detachFromFlutterEngine()
        flutterEngine.destroy()
        super.onDestroy()
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    /**
     * Reads the text immediately before the cursor (up to [length] chars).
     * Used by [SuggestionManager] to build suggestion context.
     */
    fun getTextBeforeCursor(length: Int): String {
        return currentInputConnection
            ?.getTextBeforeCursor(length, 0)
            ?.toString()
            ?: ""
    }

    /**
     * Deletes the word immediately before the cursor.
     *
     * Reads up to 100 characters before the cursor, finds the previous word
     * boundary (the last whitespace after trimming trailing spaces), then calls
     * [InputConnection.deleteSurroundingText] to remove it in one operation.
     */
    private fun deleteWordBeforeCursor() {
        val ic = currentInputConnection ?: return
        val textBefore = ic.getTextBeforeCursor(100, 0)?.toString() ?: return
        if (textBefore.isEmpty()) return

        // Strip trailing whitespace first so swipe-left on "hello " deletes "hello".
        val trimmed = textBefore.trimEnd()
        val lastSpace = trimmed.lastIndexOf(' ')
        // Delete only the word itself (not the preceding space separator) so the
        // cursor lands naturally after the previous word.
        // e.g. "hello world" → delete "world" (5) → "hello "
        val wordLength = if (lastSpace >= 0) trimmed.length - lastSpace - 1 else trimmed.length
        val trailingSpaces = textBefore.length - trimmed.length
        ic.deleteSurroundingText(wordLength + trailingSpaces, 0)
    }
}
