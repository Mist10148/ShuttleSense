import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/practice/coach_guide_panel.dart';

void main() {
  testWidgets('guide exposes grounded moments and inspectable sources', (tester) async {
    double? sought;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CoachGuidePanel(
              loading: false,
              error: null,
              stale: false,
              onRetry: () {},
              onSeek: (s) => sought = s,
              report: {
                'summary': 'Session counts',
                'ai_overall_guidance': 'Session overview',
                'generated_by': 'gemini',
                'limitation': 'Review video',
                'sources': [
                  {'id': 'kb:reach', 'title': 'Reach', 'text': 'Practice comfortably.'},
                ],
                'coaching_points': [
                  {
                    'title': 'Reach',
                    'explanation': 'Review your reach.',
                    'moments': [18.5],
                    'knowledge_ids': ['kb:reach'],
                  },
                ],
                'drills': [
                  {
                    'title': 'Shadow swing',
                    'instruction': 'Practice slowly.',
                    'moments': [18.5],
                    'knowledge_ids': ['kb:reach'],
                  },
                ],
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Session overview'), findsOneWidget);
    expect(find.text('00:18'), findsWidgets);
    await tester.tap(find.text('00:18').first);
    expect(sought, 18.5);
    await tester.tap(find.text('Source: Reach').first);
    await tester.pumpAndSettle();
    expect(find.text('Practice comfortably.'), findsOneWidget);
  });

  testWidgets('loading, retry and stale status stay visible', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CoachGuidePanel(
            loading: false,
            error: 'offline',
            stale: true,
            report: null,
            onRetry: () => retried = true,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Unsaved event changes'), findsOneWidget);
    await tester.tap(find.text('Retry coaching guide'));
    expect(retried, isTrue);
  });
  testWidgets('reduced motion skips the star transition', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: CoachGuidePanel(
              loading: true,
              error: null,
              stale: false,
              report: null,
              onRetry: () {},
              onSeek: (_) {},
            ),
          ),
        ),
      ),
    );
    final align = tester.widget<AnimatedAlign>(find.byType(AnimatedAlign).first);
    expect(align.duration, Duration.zero);
    expect(find.text('Preparing your coaching summary...'), findsOneWidget);
  });
  testWidgets('rate limited AI does not duplicate rules-based guidance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CoachGuidePanel(
            loading: false,
            error: null,
            stale: false,
            onRetry: () {},
            onSeek: (_) {},
            report: {
              'generated_by': 'rules',
              'fallback_reason': 'rate_limited',
              'summary': 'Rules summary',
              'guidance': [
                {'text': 'Rules tip'},
              ],
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('rate-limited'), findsOneWidget);
    expect(find.text('Rules tip'), findsNothing);
    expect(find.text('Retry AI guide'), findsOneWidget);
  });
}
