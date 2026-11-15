import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/repositories/analysis_repository.dart';
import 'package:shuttlesense_app/features/mode/mode_screen.dart';
import 'package:shuttlesense_app/features/calibration/calibration_screen.dart';
import 'package:shuttlesense_app/features/watch/watch_screen.dart';
import 'fakes/fake_api_client.dart';
import 'fakes/fake_file_picker.dart';
import 'helpers.dart';

class _SuggestionApi extends FakeApiClient {
  @override
  Future<Map<String, dynamic>> suggestMatchType(
    String videoId,
    List<({double x, double y})> corners,
  ) async => {'suggestion': 'doubles', 'detail': 'Please confirm.'};
}

void main() {
  Health health(bool enabled) => Health(
    version: '0.1',
    schemaVersion: '1.6',
    device: 'cpu',
    authRequired: false,
    stages: const [],
    watchVideo: enabled,
  );

  testWidgets('watch mode is available only when the backend advertises it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpScreen(
      tester,
      const ModeScreen(),
      size: laptop,
      overrides: [healthProvider.overrideWith((ref) async => health(false))],
    );
    final disabled = tester.widget<InkWell>(
      find.descendant(
        of: find.ancestor(of: find.text('Watch & Analyze'), matching: find.byType(Card)),
        matching: find.byType(InkWell),
      ),
    );
    expect(disabled.onTap, isNull);
    await tester.pumpWidget(const SizedBox());
    await pumpScreen(
      tester,
      const ModeScreen(),
      size: laptop,
      overrides: [healthProvider.overrideWith((ref) async => health(true))],
    );
    final enabled = tester.widget<InkWell>(
      find.descendant(
        of: find.ancestor(of: find.text('Watch & Analyze'), matching: find.byType(Card)),
        matching: find.byType(InkWell),
      ),
    );
    expect(enabled.onTap, isNotNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('manual format must be chosen and auto requires court corners', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    await pumpScreen(
      tester,
      const WatchScreen(),
      size: laptop,
      api: FakeApiClient(),
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '0.1',
            schemaVersion: '1.6',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
            watchMatchType: true,
            watchRealtime: true,
            watchBackground: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<bool>>(
            find.ancestor(of: find.text('Real time'), matching: find.byType(SegmentedButton<bool>)),
          )
          .selected,
      {true},
    );
    await tester.tap(find.text('Analyze every frame'));
    await tester.pump();
    expect(find.textContaining('Playback waits for analysis'), findsOneWidget);
    await tester.ensureVisible(find.text('Start analysis'));
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('Doubles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doubles'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNotNull,
    );
    await tester.ensureVisible(find.text('Suggest automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest automatically'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Suggest match format'));
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Suggest match format'))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNull,
    );
  });

  testWidgets('court corners can be suggested after choosing a format and cleared', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    final api = FakeApiClient()
      ..suggestedCorners = [
        (x: 200.0, y: 650.0),
        (x: 1000.0, y: 650.0),
        (x: 800.0, y: 200.0),
        (x: 400.0, y: 200.0),
      ];
    await pumpScreen(
      tester,
      const WatchScreen(),
      size: laptop,
      api: api,
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '1',
            schemaVersion: '1',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Find corners automatically'))
          .onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('Doubles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doubles'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check the suggested singles court corners'), findsOneWidget);
    expect(tester.widget<CornerCanvas>(find.byType(CornerCanvas)).corners, hasLength(4));
    await tester.ensureVisible(find.text('Clear corners'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear corners'));
    await tester.pumpAndSettle();
    expect(tester.widget<CornerCanvas>(find.byType(CornerCanvas)).corners, isEmpty);
  });

  testWidgets('failed court detection leaves manual placement available', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    await pumpScreen(
      tester,
      const WatchScreen(),
      size: laptop,
      api: FakeApiClient(),
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '1',
            schemaVersion: '1',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Singles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Singles'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not find the court reliably'), findsOneWidget);
    tester.widget<CornerCanvas>(find.byType(CornerCanvas)).onTap((x: 200, y: 650));
    await tester.pump();
    expect(tester.widget<CornerCanvas>(find.byType(CornerCanvas)).corners, hasLength(1));
  });

  testWidgets('automatic suggestion requires confirmation and can be overridden', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    await pumpScreen(
      tester,
      const WatchScreen(),
      size: laptop,
      api: _SuggestionApi(),
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '0.1',
            schemaVersion: '1.6',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
            watchMatchType: true,
            watchRealtime: true,
            watchBackground: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Suggest automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest automatically'));
    await tester.pumpAndSettle();
    for (final point in [
      (x: 100.0, y: 650.0),
      (x: 1180.0, y: 650.0),
      (x: 800.0, y: 90.0),
      (x: 480.0, y: 90.0),
    ]) {
      tester.widget<CornerCanvas>(find.byType(CornerCanvas)).onTap(point);
      await tester.pump();
    }
    await tester.ensureVisible(find.text('Suggest match format'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest match format'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Suggested: doubles'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('Singles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Singles'));
    await tester.pump();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Singles')).selected, isTrue);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNotNull,
    );
  });
}
