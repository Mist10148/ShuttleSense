import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/app.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/responsive/adaptive_shell.dart';
import 'package:shuttlesense_app/core/responsive/breakpoints.dart';
import 'package:shuttlesense_app/features/history/history_screen.dart';
import 'package:shuttlesense_app/features/results/widgets/results_layout.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';

/// Phone portrait, tablet, laptop (docs/ARCHITECTURE.md §4).
const phone = Size(360, 780);
const tablet = Size(800, 1100);
const laptop = Size(1280, 800);

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> pumpApp(WidgetTester tester, {String? savedServer}) async {
  SharedPreferences.setMockInitialValues({'server.baseUrl': ?savedServer});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const ShuttleSenseApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Widget box(String label) => Container(key: Key(label), height: 120, color: Colors.grey);

void main() {
  test('breakpoints follow Material 3 window classes', () {
    expect(Breakpoints.forWidth(360), WindowClass.compact);
    expect(Breakpoints.forWidth(599), WindowClass.compact);
    expect(Breakpoints.forWidth(600), WindowClass.medium);
    expect(Breakpoints.forWidth(1023), WindowClass.medium);
    expect(Breakpoints.forWidth(1024), WindowClass.expanded);
  });

  testWidgets('first launch without a server shows the connect screen', (tester) async {
    setSize(tester, phone);
    await pumpApp(tester);
    expect(find.text('Connect to server'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  group('adaptive shell', () {
    testWidgets('phone uses a bottom navigation bar and a compact top bar', (tester) async {
      setSize(tester, phone);
      await pumpApp(tester, savedServer: 'http://localhost:8000');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(IconRail), findsNothing);
      expect(find.byTooltip('Search analyses'), findsOneWidget);
      expect(find.text('Home'), findsWidgets);
      expect(find.text('Start an analysis'), findsOneWidget);
    });

    for (final (name, size) in [('tablet', tablet), ('laptop', laptop)]) {
      testWidgets('$name uses the icon rail inside the glass shell', (tester) async {
        setSize(tester, size);
        await pumpApp(tester, savedServer: 'http://localhost:8000');
        expect(find.byType(IconRail), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byTooltip('History'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Search analyses'), findsOneWidget);
      });
    }

    testWidgets('rail buttons switch tabs and the theme', (tester) async {
      setSize(tester, laptop);
      await pumpApp(tester, savedServer: 'http://localhost:8000');
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Connection'), findsOneWidget);

      expect(Theme.of(tester.element(find.byType(IconRail))).brightness, Brightness.light);
      await tester.tap(find.byTooltip('Switch to dark theme'));
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byType(IconRail))).brightness, Brightness.dark);
    });

    testWidgets('top bar search opens History with the query', (tester) async {
      setSize(tester, laptop);
      await pumpApp(tester, savedServer: 'http://localhost:8000');
      await tester.enterText(find.widgetWithText(TextField, 'Search analyses'), ' rally ');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final history = find.byType(HistoryScreen);
      expect(history, findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(history));
      expect(container.read(historyQueryProvider), 'rally');
    });
  });

  group('results layout', () {
    Future<void> pumpLayout(WidgetTester tester, Size size) async {
      setSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ResultsLayout(
              video: const AspectRatio(
                aspectRatio: 16 / 9,
                child: ColoredBox(color: Colors.black),
              ),
              status: box('status'),
              timeline: ListView(children: [for (var i = 0; i < 30; i++) Text('hit $i')]),
              minimap: box('minimap'),
              scoreboard: box('scoreboard'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final (name, size) in [
      ('phone', phone),
      ('phone landscape', const Size(780, 360)),
      ('tablet', tablet),
      ('tablet landscape', const Size(1100, 800)),
      ('short desktop window', const Size(1000, 540)),
      ('laptop', laptop),
      ('wide desktop', const Size(1920, 1080)),
    ]) {
      testWidgets('$name renders without overflow', (tester) async {
        await pumpLayout(tester, size);
        expect(tester.takeException(), isNull);
        // One section at a time on every size, so each gets the full width.
        expect(find.byType(TabBar), findsOneWidget);
        expect(find.byKey(const Key('status')), findsOneWidget);
        // The court is always on screen with the video, not behind a tab.
        expect(find.byKey(const Key('minimap')), findsOneWidget);
        await tester.ensureVisible(find.text('Score'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Score'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('scoreboard')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a short window keeps the timeline usable', (tester) async {
      await pumpLayout(tester, const Size(1000, 540));
      expect(tester.getSize(find.byType(ListView)).height, greaterThan(120));
      // A tall tablet still shows the video at full width.
      await pumpLayout(tester, tablet);
      final video = tester.getSize(find.byType(AspectRatio));
      expect(video.width / video.height, closeTo(16 / 9, 0.01));
      expect(video.width, greaterThan(400));
    });

    test('the right column stays between 360 and 440 dp', () {
      expect(ResultsLayout.sidePanelWidth(800), 360);
      expect(ResultsLayout.sidePanelWidth(1280), 384);
      expect(ResultsLayout.sidePanelWidth(1920), 440);
    });
  });
}
