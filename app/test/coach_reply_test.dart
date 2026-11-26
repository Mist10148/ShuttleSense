import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/coach/coach_screen.dart';
import 'package:shuttlesense_app/shared/widgets/coach_reply.dart';

void main() {
  testWidgets('coach formats selectable replies and preserves a literal question', (tester) async {
    const reply =
        '## Timing\n\nWatch the **shuttle**.\n\n1. *Move* into position and keep your racket up until the return.\n- Recover';
    Widget bubble(String role, String text) => CoachBubble(
      turn: CoachTurn(
        message: ChatMessage(role: role, text: text, at: DateTime.utc(2026)),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: Column(children: [bubble('user', '**why**'), bubble('assistant', reply)]),
            ),
          ),
        ),
      ),
    );
    expect(find.widgetWithText(SelectableText, '**why**'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(CoachReply), matching: find.byType(SelectionArea)),
      findsOneWidget,
    );
    expect(find.text('Timing'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
    final spans = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.textSpan)
        .whereType<TextSpan>()
        .expand((s) => s.children ?? <InlineSpan>[])
        .whereType<TextSpan>();
    expect(spans.singleWhere((s) => s.text == 'shuttle').style!.fontWeight, FontWeight.bold);
    expect(spans.singleWhere((s) => s.text == 'Move').style!.fontStyle, FontStyle.italic);
    expect(tester.takeException(), isNull);
  });
}
