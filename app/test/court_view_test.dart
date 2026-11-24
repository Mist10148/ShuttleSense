import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/shared/widgets/court_view_field.dart';
import 'package:shuttlesense_app/shared/widgets/match_setup_field.dart';

void main() {
  group('SideNames.fromCorners', () {
    test('behind the court: the near baseline is below the far one', () {
      final names = SideNames.fromCorners(const [
        (x: 100, y: 700),
        (x: 1180, y: 700),
        (x: 900, y: 200),
        (x: 380, y: 200),
      ]);
      expect(names, SideNames.ends);
      expect(names.player('near_2'), 'Near 2');
    });

    test('side-on with the near end on the left reads Left / Right', () {
      // Back left, front left, front right, back right.
      final names = SideNames.fromCorners(const [
        (x: 200, y: 250),
        (x: 60, y: 650),
        (x: 1220, y: 650),
        (x: 1080, y: 250),
      ]);
      expect(names, SideNames.leftRight);
      expect(names.player('near'), 'Left');
      expect(names.player('far_1'), 'Right 1');
      expect(names.sideOn, isTrue);
    });

    test('side-on with the near end on the right reads Right / Left', () {
      final names = SideNames.fromCorners(const [
        (x: 1080, y: 650),
        (x: 1220, y: 250),
        (x: 60, y: 250),
        (x: 200, y: 650),
      ]);
      expect(names.side('near'), 'Right');
      expect(names.side('far'), 'Left');
    });

    test('no corners keeps Near / Far', () {
      expect(SideNames.fromCorners(null), SideNames.ends);
    });
  });

  test('corner order follows the camera position', () {
    expect(cornerNamesFor(CourtView.end).first, 'Near left');
    expect(cornerOrderFor(CourtView.side), 'back left, front left, front right, back right');
  });

  testWidgets('first server reads Left / Right for a side-on camera', (tester) async {
    MatchSetup? picked;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MatchSetupField(
              value: kDefaultMatchSetup,
              sides: SideNames.leftRight,
              onChanged: (m) => picked = m,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Near'), findsNothing);
    await tester.tap(find.text('Left'));
    await tester.pumpAndSettle();
    expect(picked?.firstServer, 'near'); // the server still says near
  });

  testWidgets('the camera position choice switches the side names it describes', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: CourtViewField()),
        ),
      ),
    );
    expect(find.textContaining('called Near and Far'), findsOneWidget);
    await tester.tap(find.text('Side-on'));
    await tester.pumpAndSettle();
    expect(find.textContaining('called Left and Right'), findsOneWidget);
  });
}
