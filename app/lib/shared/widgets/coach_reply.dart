import 'package:flutter/material.dart';

/// Selectable blocks for the Markdown used in assistant replies.
class CoachReply extends StatelessWidget {
  const CoachReply(this.source, {super.key});

  final String source;

  static final _heading = RegExp(r'^ {0,3}(#{1,6})\s+(.+)$');
  static final _item = RegExp(r'^\s*([-+*]|\d{1,9}[.)])\s+(.+)$');
  static final _emphasis = RegExp(r'(\*\*|__)(?=\S)(.+?)\1|(\*|_)(?=\S)(.+?)\3');

  static Widget _text(String text, [TextStyle? style]) {
    final spans = <TextSpan>[];
    var position = 0;
    for (final match in _emphasis.allMatches(text)) {
      spans.add(TextSpan(text: text.substring(position, match.start)));
      final bold = match.group(1) != null;
      spans.add(
        TextSpan(
          text: match.group(bold ? 2 : 4),
          style: bold
              ? const TextStyle(fontWeight: FontWeight.bold)
              : const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
      position = match.end;
    }
    if (spans.isEmpty) return Text(text, style: style);
    spans.add(TextSpan(text: text.substring(position)));
    return Text.rich(TextSpan(children: spans), style: style);
  }

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    final lines = source.split('\n');
    var index = 0;
    while (index < lines.length) {
      final line = lines[index++].trimRight();
      if (line.trim().isEmpty) continue;
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        final theme = Theme.of(context).textTheme;
        blocks.add(
          Semantics(
            header: true,
            child: _text(
              heading[2]!,
              heading[1]!.length <= 2 ? theme.titleLarge : theme.titleMedium,
            ),
          ),
        );
        continue;
      }
      final item = _item.firstMatch(line);
      final body = [item?[2] ?? line];
      while (index < lines.length &&
          lines[index].trim().isNotEmpty &&
          !_heading.hasMatch(lines[index]) &&
          !_item.hasMatch(lines[index])) {
        body.add(lines[index++].trim());
      }
      final content = _text(body.join(' '));
      if (item == null) {
        blocks.add(content);
      } else {
        final marker = item[1]!;
        blocks.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(marker.length == 1 ? '•' : marker),
              const SizedBox(width: 8),
              Expanded(child: content),
            ],
          ),
        );
      }
    }
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: blocks,
      ),
    );
  }
}
