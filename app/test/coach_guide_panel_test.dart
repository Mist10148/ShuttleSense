import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/features/practice/coach_guide_panel.dart';

void main() {
  testWidgets('guide exposes grounded moments and inspectable sources', (tester) async {
    double? sought;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
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
    expect(find.text('00:18'), findsNothing);
    await tester.tap(find.text('Detailed Analysis'));
    await tester.pumpAndSettle();
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
        theme: AppTheme.light(),
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
  testWidgets('the cards and loading status remain visible while the guide is pending', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
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
    expect(find.text('Overall Summary'), findsOneWidget);
    expect(find.text('Detailed Analysis'), findsOneWidget);
    expect(find.text('Follow-up Questions'), findsOneWidget);
    expect(find.text('Preparing your coaching summary...'), findsOneWidget);
  });
  testWidgets('rate limited AI does not duplicate rules-based guidance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
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
    expect(find.text('Rules tip'), findsOneWidget);
    expect(find.text('Retry AI guide'), findsOneWidget);
  });

  testWidgets('follow-up retains a failed draft across cards and resets for new evidence', (
    tester,
  ) async {
    var version = 'saved-v1';
    var sends = 0;
    double? sought;
    late VoidCallback changeVersion;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) {
                changeVersion = () => setState(() => version = 'saved-v2');
                return CoachGuidePanel(
                  loading: false,
                  error: null,
                  stale: false,
                  canAsk: true,
                  onRetry: () {},
                  onSeek: (s) => sought = s,
                  report: {
                    'context_version': version,
                    'generated_by': 'gemini',
                    'evidence': [
                      {'id': 'pose', 'moment_s': 2.5, 'description': 'Reach'},
                    ],
                  },
                  onAsk: (question, contextVersion, history, _) async* {
                    expect(question, 'Why flag this?');
                    expect(contextVersion, 'saved-v1');
                    expect(history, isEmpty);
                    if (++sends == 1) {
                      yield {'type': 'error', 'status': 429, 'detail': 'Quota exhausted'};
                      return;
                    }
                    yield {
                      'type': 'done',
                      'message': {
                        'role': 'assistant',
                        'text': 'Check your reach [t=2.5s]',
                        'at': '2026-11-24T00:00:00Z',
                        'citations': [
                          {'frame': 75, 'time_s': 2.5},
                        ],
                      },
                    };
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Follow-up Questions'));
    await tester.pumpAndSettle();
    expect(sends, 0);
    await tester.enterText(find.byType(TextField), 'Why flag this?');
    await tester.pump();
    await tester.tap(find.text('Send question'));
    await tester.pumpAndSettle();
    expect(find.text('Quota exhausted'), findsOneWidget);
    await tester.tap(find.text('Overall Summary'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow-up Questions'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Why flag this?');
    await tester.tap(find.text('Send question'));
    await tester.pumpAndSettle();
    expect(find.text('Check your reach'), findsOneWidget);
    await tester.tap(find.text('0:02.5'));
    expect(sought, 2.5);
    changeVersion();
    await tester.pumpAndSettle();
    expect(find.text('Check your reach'), findsNothing);
  });
}
