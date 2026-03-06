import 'package:flutter/material.dart';
import '../platform/keyboard_channel.dart';

/// The suggestion bar displayed above the keyboard rows.
///
/// Shows up to three word predictions that were pushed by the Kotlin
/// [SuggestionManager].  Tapping a chip calls [onSuggestionSelected] which
/// triggers [KeyboardChannel.commitSuggestion].
///
/// Each suggestion is rendered as a pill-shaped chip, matching the compact
/// Samsung Keyboard style.  The bar uses an [AnimatedSwitcher] to cross-fade
/// whenever the suggestion list changes, keeping visual noise low during fast
/// typing.
class SuggestionBar extends StatefulWidget {
  const SuggestionBar({
    super.key,
    required this.channel,
  });

  final KeyboardChannel channel;

  @override
  State<SuggestionBar> createState() => _SuggestionBarState();
}

class _SuggestionBarState extends State<SuggestionBar> {
  List<String> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    widget.channel.addSuggestionListener(_onSuggestionsUpdated);
  }

  @override
  void dispose() {
    widget.channel.removeSuggestionListener(_onSuggestionsUpdated);
    super.dispose();
  }

  void _onSuggestionsUpdated(List<String> suggestions) {
    if (mounted) {
      setState(() => _suggestions = suggestions);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 44,
      color: theme.colorScheme.surfaceContainerLow,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 120),
        child: _suggestions.isEmpty
            ? const SizedBox.expand(key: ValueKey('empty'))
            : _buildChipRow(theme),
      ),
    );
  }

  Widget _buildChipRow(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final chipBg = isDark
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.surfaceContainer;

    return Row(
      key: ValueKey(_suggestions.join()),
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (int i = 0; i < _suggestions.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Material(
                color: chipBg,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => widget.channel.commitSuggestion(_suggestions[i]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    child: Center(
                      child: Text(
                        _suggestions[i],
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
