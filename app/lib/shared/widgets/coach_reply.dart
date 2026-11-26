import 'package:flutter/material.dart';

/// Selectable blocks for the Markdown used in assistant replies.
class CoachReply extends StatelessWidget {
  const CoachReply(this.source, {super.key});

  final String source;

  static final _heading = RegExp(r'^ {0,3}(#{1,6})\s+(.+)$');
  static final _item = RegExp(r'^([ \t]*)([-+*]|\d{1,9}[.)])\s+(.+)$');
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
      final body = [item?[3] ?? line];
      while (index < lines.length &&
          !_heading.hasMatch(lines[index]) &&
          !_item.hasMatch(lines[index])) {
        if (lines[index].trim().isEmpty) {
          // An indented paragraph after a blank line still belongs to this item.
          var next = index;
          while (next < lines.length && lines[next].trim().isEmpty) {
            next++;
          }
          if (item == null ||
              next == lines.length ||
              _heading.hasMatch(lines[next]) ||
              _item.hasMatch(lines[next]) ||
              lines[next].length - lines[next].trimLeft().length <= item[1]!.length) {
            break;
          }
          body.add('');
          index = next;
        }
        body.add(lines[index++].trim());
      }
      final content = _text(body.join('\n').replaceAll('\\\n', '\n'));
      if (item == null) {
        blocks.add(content);
      } else {
        final marker = item[2]!;
        // Cap indentation so long replies still have room on a phone.
        final indent = item[1]!.replaceAll('\t', '    ').length.clamp(0, 8);
        blocks.add(
          Padding(
            padding: EdgeInsetsDirectional.only(start: indent * 8.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(marker.length == 1 ? '•' : marker),
                const SizedBox(width: 8),
                Expanded(child: content),
              ],
            ),
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
