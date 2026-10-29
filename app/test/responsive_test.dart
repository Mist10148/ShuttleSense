import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/app.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/responsive/breakpoints.dart';
import 'package:shuttlesense_app/features/results/widgets/results_layout.dart';

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
    testWidgets('phone uses a bottom navigation bar', (tester) async {
      setSize(tester, phone);
      await pumpApp(tester, savedServer: 'http://localhost:8000');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('New analysis'), findsOneWidget);
    });

    testWidgets('tablet uses a compact navigation rail', (tester) async {
      setSize(tester, tablet);
      await pumpApp(tester, savedServer: 'http://localhost:8000');
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isFalse);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('laptop uses an extended navigation rail', (tester) async {
      setSize(tester, laptop);
      await pumpApp(tester, savedServer: 'http://localhost:8000');
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isTrue);
    });
  });

  group('results layout', () {
    Future<void> pumpLayout(WidgetTester tester, Size size) async {
      setSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
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

    for (final (name, size, tabs) in [
      ('phone', phone, true),
      ('tablet', tablet, false),
      ('laptop', laptop, false),
      ('wide desktop', const Size(1920, 1080), false),
    ]) {
      testWidgets('$name renders without overflow', (tester) async {
        await pumpLayout(tester, size);
        expect(tester.takeException(), isNull);
        expect(find.byType(TabBar), tabs ? findsOneWidget : findsNothing);
        expect(find.byKey(const Key('status')), findsOneWidget);
        if (!tabs) {
          expect(find.byKey(const Key('minimap')), findsOneWidget);
          expect(find.byKey(const Key('scoreboard')), findsOneWidget);
        }
      });
    }
  });
}
