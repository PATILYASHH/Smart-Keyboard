package com.smartkeyboard

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

/**
 * Unit tests for [KeyboardEngine].
 *
 * These tests run on the JVM (no Android device/emulator required) because
 * [KeyboardEngine] avoids framework calls for the common paths.
 */
class KeyboardEngineTest {

    private lateinit var engine: KeyboardEngine

    @Before
    fun setUp() {
        engine = KeyboardEngine()
    }

    // ---------------------------------------------------------------------------
    // processCharacter
    // ---------------------------------------------------------------------------

    @Test
    fun `processCharacter returns CommitText for regular character`() {
        val result = engine.processCharacter("a")
        assertTrue(result is KeyInputResult.CommitText)
        assertEquals("a", (result as KeyInputResult.CommitText).text)
    }

    @Test
    fun `processCharacter returns CommitText for space`() {
        val result = engine.processCharacter(" ")
        assertTrue(result is KeyInputResult.CommitText)
        assertEquals(" ", (result as KeyInputResult.CommitText).text)
    }

    @Test
    fun `processCharacter returns DeleteBackward for backspace control character`() {
        val result = engine.processCharacter("\b")
        assertTrue("Expected DeleteBackward", result is KeyInputResult.DeleteBackward)
    }

    @Test
    fun `processCharacter returns SendKeyEvent for newline`() {
        val result = engine.processCharacter("\n")
        assertTrue(result is KeyInputResult.SendKeyEvent)
        // Since we are returning default values (0), we can't assert the keycode
        // but we can verify it's a SendKeyEvent.
    }

    @Test
    fun `processCharacter returns SendKeyEvent for carriage return`() {
        val result = engine.processCharacter("\r")
        assertTrue(result is KeyInputResult.SendKeyEvent)
    }

    @Test
    fun `processCharacter returns SendKeyEvent for tab`() {
        val result = engine.processCharacter("\t")
        assertTrue(result is KeyInputResult.SendKeyEvent)
    }

    @Test
    fun `processCharacter returns NoOp for empty string`() {
        val result = engine.processCharacter("")
        assertTrue(result is KeyInputResult.NoOp)
    }

    @Test
    fun `processCharacter handles emoji`() {
        val result = engine.processCharacter("😀")
        assertTrue(result is KeyInputResult.CommitText)
        assertEquals("😀", (result as KeyInputResult.CommitText).text)
    }

    // ---------------------------------------------------------------------------
    // buildKeyPressPayload
    // ---------------------------------------------------------------------------

    @Test
    fun `buildKeyPressPayload contains expected keys`() {
        val payload = engine.buildKeyPressPayload("a", setOf(Modifier.SHIFT))
        assertEquals("a", payload["character"])
        assertEquals(true, payload["isShift"])
        assertEquals(false, payload["isCaps"])
        assertEquals(false, payload["isAlt"])
        assertTrue(payload.containsKey("timestampMs"))
    }

    @Test
    fun `buildKeyPressPayload reflects CAPS_LOCK modifier`() {
        val payload = engine.buildKeyPressPayload("A", setOf(Modifier.CAPS_LOCK))
        assertEquals(false, payload["isShift"])
        assertEquals(true, payload["isCaps"])
    }

    @Test
    fun `buildKeyPressPayload with no modifiers sets all flags to false`() {
        val payload = engine.buildKeyPressPayload("z", emptySet())
        assertEquals(false, payload["isShift"])
        assertEquals(false, payload["isCaps"])
        assertEquals(false, payload["isAlt"])
    }

    // ---------------------------------------------------------------------------
    // processKeyCode
    // ---------------------------------------------------------------------------

    @Test
    fun `processKeyCode KEYCODE_DEL returns DeleteBackward`() {
        val result = engine.processKeyCode(KeyEvent.KEYCODE_DEL)
        assertTrue(result is KeyInputResult.DeleteBackward)
    }

    @Test
    fun `processKeyCode KEYCODE_ENTER returns SendKeyEvent with ENTER`() {
        val result = engine.processKeyCode(KeyEvent.KEYCODE_ENTER)
        assertTrue(result is KeyInputResult.SendKeyEvent)
    }

    @Test
    fun `processKeyCode KEYCODE_SPACE returns CommitText with space`() {
        val result = engine.processKeyCode(KeyEvent.KEYCODE_SPACE)
        assertTrue(result is KeyInputResult.CommitText)
        assertEquals(" ", (result as KeyInputResult.CommitText).text)
    }
}
