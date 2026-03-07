package com.smartkeyboard

/**
 * SuggestionManager
 *
 * Maintains the current typing context and derives word suggestions that are
 * pushed to Flutter via [FlutterChannelManager].
 *
 * Architecture notes
 * ------------------
 * • The suggestion pipeline is intentionally kept synchronous and lightweight
 *   so it can run on the main thread without risking frame drops in Flutter.
 * • The built-in dictionary is a small in-memory word list that covers common
 *   English words.  In a production build, replace [dictionary] with a Trie or
 *   ONNX language model.  The public contract ([computeSuggestions],
 *   [onCharacterAdded], [reset]) does not change when swapping the backing store.
 * • [computeSuggestions] is the only public entry point needed by the channel
 *   manager.  Swap the internal implementation without changing the contract.
 */
class SuggestionManager {

    // ---------------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------------

    /** The word fragment currently being typed (resets on space/punctuation). */
    private var currentToken: String = ""

    // Stub dictionary – replace with a proper language model in production.
    private val dictionary: List<String> = listOf(
        "the", "that", "this", "they", "then", "there", "their", "these",
        "hello", "help", "here", "he", "her", "him", "his",
        "world", "work", "word", "would", "were",
        "and", "are", "a", "an", "at", "as",
        "be", "by", "but",
        "can", "could", "come",
        "do", "did", "does",
        "for", "from",
        "get", "go", "got", "good",
        "have", "has", "had",
        "i", "in", "it", "if", "is",
        "just",
        "know",
        "like", "love",
        "me", "my", "make",
        "not", "no", "new", "now",
        "of", "on", "or", "out", "one",
        "people", "place",
        "say", "see", "she", "so", "some", "said",
        "time", "to", "top", "two",
        "up", "us", "use",
        "very",
        "want", "was", "way", "we", "what", "when", "which", "who", "will", "with",
        "you", "your", "year"
    )

    // ---------------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------------

    /**
     * Appends [character] to the current token and returns a fresh suggestion
     * list (up to [maxSuggestions] items).
     *
     * Call this after every key commit so Flutter always has up-to-date results.
     */
    fun onCharacterAdded(character: String, maxSuggestions: Int = 3): List<String> {
        return when {
            character == " " || character.isPunctuation() -> {
                currentToken = ""
                emptyList()
            }
            character == "\b" -> {
                if (currentToken.isNotEmpty()) {
                    currentToken = currentToken.dropLast(1)
                }
                if (currentToken.isEmpty()) {
                    emptyList()
                } else {
                    computeSuggestions(currentToken, maxSuggestions)
                }
            }
            else -> {
                currentToken += character.lowercase()
                computeSuggestions(currentToken, maxSuggestions)
            }
        }
    }

    /**
     * Returns up to [maxSuggestions] dictionary entries that start with [prefix].
     * If [prefix] is blank the list is empty (nothing to suggest yet).
     */
    fun computeSuggestions(prefix: String, maxSuggestions: Int = 3): List<String> {
        if (prefix.isBlank()) return emptyList()
        return dictionary
            .filter { it.startsWith(prefix, ignoreCase = true) && it != prefix }
            .take(maxSuggestions)
    }

    /**
     * Resets internal state when the input field changes or is dismissed.
     */
    fun reset() {
        currentToken = ""
    }

    // ---------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------

    private fun String.isPunctuation(): Boolean =
        this.length == 1 && !this[0].isLetterOrDigit() && this[0] != '\''
}
