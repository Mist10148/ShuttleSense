// Theme switch animations (docs/THEMES.md): the right animation for each change, the theme
// changing at the planned moment, a newer change cancelling the running one, and reduced
// motion or the setting skipping the animation.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/audio/skin_sounds.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/theme/app_skin.dart';
import 'package:shuttlesense_app/features/skins/fx/backrooms_plan.dart';
import 'package:shuttlesense_app/features/skins/fx/backrooms_switch_overlay.dart';
import 'package:shuttlesense_app/features/skins/fx/denia_plan.dart';
import 'package:shuttlesense_app/features/skins/fx/denia_switch_overlay.dart';
import 'package:shuttlesense_app/features/skins/fx/skin_fx_host.dart';
import 'package:shuttlesense_app/features/skins/fx/skin_switch.dart';

import 'helpers.dart';

/// Records what would have played.
class RecordingSounds implements SkinSounds {
  final calls = <String>[];

  @override
  StopSound backroomsClick() {
    calls.add('click');
    return () => calls.add('stop click');
  }

  @override
  StopSound backroomsHum() {
    calls.add('hum');
    return () => calls.add('stop hum');
  }

  @override
  StopSound deniaScore(DeniaScore score) {
    calls.add('denia ${score.chimes.length}');
    return () => calls.add('stop denia');
  }

  @override
  void stopAll() => calls.add('stopAll');

  @override
  void unlock() => calls.add('unlock');
}

late ProviderContainer _c;

Future<RecordingSounds> _pumpHost(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  bool reduceMotion = false,
}) async {
  setSize(tester, laptop);
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  final sounds = RecordingSounds();
  _c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(p),
      skinSoundsProvider.overrideWithValue(sounds),
    ],
  );
  addTearDown(_c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _c,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: SkinFxHost(child: child!),
        ),
        home: const Scaffold(body: Text('page')),
      ),
    ),
  );
  return sounds;
}

void _request(AppSkin to, {bool reduceMotion = false, bool fromSettings = false}) => _c
    .read(skinSwitchProvider.notifier)
    .request(to, reduceMotion: reduceMotion, fromSettings: fromSettings);

AppSkin get _skin => _c.read(appSkinProvider);

void main() {
  group('plans', () {
    test('Backrooms timings match Wonderboard', () {
      expect(BackroomsPlan.applyAt, 150);
      expect(BackroomsPlan.logoAt, 2150);
      expect(BackroomsPlan.revealAt, 4150);
      expect(BackroomsPlan.endAt, 9150);
      expect(BackroomsPlan.humVolume(0, 10000), 0.6);
      expect(BackroomsPlan.humVolume(5000, 10000), closeTo(0.3, 1e-9));
      expect(BackroomsPlan.humVolume(12000, 10000), 0);
      expect(BackroomsPlan.humVolume(10, 0), 0);
    });

    test('Denia plans and bubbles stay inside their windows, the same for a seed', () {
      for (final kind in DeniaSwitchKind.values) {
        final p = kind.plan;
        final b = deniaBubbles(p, 7);
        expect(b, hasLength(p.bubbles));
        expect(deniaBubbles(p, 7).map((x) => x.popAt), b.map((x) => x.popAt));
        for (final x in b) {
          expect(x.popAt, inInclusiveRange(p.popFrom, p.popTo));
          expect(x.x, inInclusiveRange(2, 98));
          expect(x.size, inInclusiveRange(26, 136));
          expect(x.delay, lessThanOrEqualTo(p.applyAt));
          expect(x.hue, inInclusiveRange(0, 2));
        }
      }
      expect(DeniaPlan.enter.applyAt, 620);
      expect(DeniaPlan.formChange.endAt, 1100);
      expect(DeniaPlan.leave.bubbles, 14);
    });

    test('Light chimes rise, Dark fall, and short switches play fewer notes and pops', () {
      List<double> freqs(DeniaSwitchKind k) =>
          deniaScore(k, deniaBubbles(k.plan)).chimes.map((n) => n.freq).toList();
      final up = freqs(DeniaSwitchKind.enterLight), down = freqs(DeniaSwitchKind.enterDark);
      expect(up, hasLength(5));
      expect(up, orderedEquals([...up]..sort()));
      expect(down, orderedEquals([...down]..sort((a, b) => b.compareTo(a))));
      expect(freqs(DeniaSwitchKind.formLight), hasLength(3));
      expect(freqs(DeniaSwitchKind.leave), [880, 659.25]);
      final s = deniaScore(DeniaSwitchKind.formDark, deniaBubbles(DeniaPlan.formChange));
      expect(s.pops.length, lessThanOrEqualTo(5));
      expect(s.whoosh.from, greaterThan(s.whoosh.to));
      for (final p in s.pops) {
        expect(p.pan.abs(), lessThanOrEqualTo(0.85));
        expect(p.freq, inInclusiveRange(320, 960));
      }
    });

    test('each change gets the right animation', () {
      expect(switchKindFor(AppSkin.classic, AppSkin.backrooms), isA<BackroomsSwitch>());
      expect(switchKindFor(AppSkin.deniaLight, AppSkin.backrooms), isA<BackroomsSwitch>());
      expect(
        switchKindFor(AppSkin.classic, AppSkin.deniaLight),
        const DeniaSwitch(DeniaSwitchKind.enterLight),
      );
      expect(
        switchKindFor(AppSkin.backrooms, AppSkin.deniaDark),
        const DeniaSwitch(DeniaSwitchKind.enterDark),
      );
      expect(
        switchKindFor(AppSkin.deniaLight, AppSkin.deniaDark),
        const DeniaSwitch(DeniaSwitchKind.formDark),
      );
      expect(
        switchKindFor(AppSkin.deniaDark, AppSkin.classic),
        const DeniaSwitch(DeniaSwitchKind.leave),
      );
      expect(switchKindFor(AppSkin.backrooms, AppSkin.classic), isNull);
      expect(switchKindFor(AppSkin.deniaDark, AppSkin.deniaDark), isNull);
    });

    test('the iris covers the window when the theme changes and then fades', () {
      const size = Size(1280, 800), origin = Offset(100, 700);
      const p = DeniaPlan.enter;
      expect(DeniaWashPainter.radiusAt(0, p, origin, size), 0);
      final full = DeniaWashPainter.radiusAt(p.applyAt.toDouble(), p, origin, size);
      expect(full, greaterThan(const Offset(1180, 700).distance));
      expect(DeniaWashPainter.opacityAt(p.applyAt + 100, p), 1);
      expect(DeniaWashPainter.opacityAt(p.endAt.toDouble(), p), 0);
    });
  });

  group('running', () {
    testWidgets('into Denia: the theme changes at 620 ms and the overlay is gone by 1800', (
      tester,
    ) async {
      final sounds = await _pumpHost(tester);
      _request(AppSkin.deniaLight);
      await tester.pump();
      expect(find.byType(DeniaSwitchOverlay), findsOneWidget);
      expect(sounds.calls, contains('denia 5'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(_skin, AppSkin.classic);
      await tester.pump(const Duration(milliseconds: 40));
      expect(_skin, AppSkin.deniaLight);
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(find.byType(DeniaSwitchOverlay), findsNothing);
      expect(_c.read(skinSwitchProvider), isNull);
    });

    testWidgets('into Backrooms: cover, theme, logo, reveal with hum, fade', (tester) async {
      final sounds = await _pumpHost(tester);
      _request(AppSkin.backrooms);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(sounds.calls, ['stopAll', 'click']);
      expect(_skin, AppSkin.classic);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_skin, AppSkin.backrooms);
      expect(find.byKey(const ValueKey('backrooms-logo')), findsNothing);
      await tester.pump(const Duration(milliseconds: 2000));
      expect(find.byKey(const ValueKey('backrooms-logo')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2000));
      expect(sounds.calls, ['stopAll', 'click', 'click', 'hum']);
      await tester.pump(const Duration(milliseconds: 5100));
      await tester.pump();
      expect(find.byType(BackroomsSwitchOverlay), findsNothing);
    });

    testWidgets('from Settings, Backrooms waits a second before it starts', (tester) async {
      final sounds = await _pumpHost(tester);
      _request(AppSkin.backrooms, fromSettings: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(sounds.calls, ['stopAll']);
      expect(_skin, AppSkin.classic);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_skin, AppSkin.backrooms);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a newer change cancels the running one and wins', (tester) async {
      final sounds = await _pumpHost(tester);
      _request(AppSkin.backrooms);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      _request(AppSkin.deniaDark);
      await tester.pump();
      expect(find.byType(BackroomsSwitchOverlay), findsNothing);
      expect(find.byType(DeniaSwitchOverlay), findsOneWidget);
      expect(sounds.calls.where((c) => c == 'stopAll'), hasLength(2));
      await tester.pump(const Duration(milliseconds: 700));
      expect(_skin, AppSkin.deniaDark);
      await tester.pump(const Duration(seconds: 2));
      expect(_c.read(skinSwitchProvider), isNull);
    });

    testWidgets('reduced motion applies at once with no overlay or sound', (tester) async {
      final sounds = await _pumpHost(tester);
      _request(AppSkin.deniaLight, reduceMotion: true);
      await tester.pump();
      expect(_skin, AppSkin.deniaLight);
      expect(find.byType(DeniaSwitchOverlay), findsNothing);
      expect(sounds.calls, ['stopAll']);
    });

    testWidgets('the animation setting off applies at once', (tester) async {
      await _pumpHost(tester, prefs: {'ui.skinFx.motion': false});
      _request(AppSkin.backrooms);
      await tester.pump();
      expect(_skin, AppSkin.backrooms);
      expect(find.byType(BackroomsSwitchOverlay), findsNothing);
    });

    testWidgets('sound off still animates but plays nothing', (tester) async {
      final sounds = await _pumpHost(tester, prefs: {'ui.skinFx.sound': false});
      _request(AppSkin.deniaDark);
      await tester.pump();
      expect(find.byType(DeniaSwitchOverlay), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(sounds.calls, ['stopAll']);
    });

    testWidgets('a change with no animation applies at once', (tester) async {
      await _pumpHost(tester, prefs: {'ui.skin': 'backrooms'});
      _request(AppSkin.classic);
      await tester.pump();
      expect(_skin, AppSkin.classic);
    });

    test('a recent tap is remembered for four seconds', () {
      final now = DateTime(2026, 11, 27, 12);
      SkinFxHost.lastTap = (const Offset(10, 20), now);
      expect(SkinFxHost.recentTap(now.add(const Duration(seconds: 3))), const Offset(10, 20));
      expect(SkinFxHost.recentTap(now.add(const Duration(seconds: 5))), isNull);
    });

    testWidgets('a tap asks the player to unlock sound for the first switch', (tester) async {
      final sounds = await _pumpHost(tester);
      expect(sounds.calls, isNot(contains('unlock')));
      await tester.tap(find.text('page'));
      expect(sounds.calls, contains('unlock'));
    });
  });
}
