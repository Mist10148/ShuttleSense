import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/shared/widgets/shuttle_speed.dart';

void main() {
  test('estimated speed bands include the lower boundary', () {
    for (final values in [
      [0.0, 30.0, 60.0, 100.0],
      [29.9, 59.9, 99.9, 450.0],
    ]) {
      expect(values.map(shuttleSpeedColor), speedColors);
    }
    for (final speed in [null, -1.0, double.nan, double.infinity, 451.0]) {
      expect(shuttleSpeedColor(speed), isNull);
    }
  });

  const start = Offset(8, 12);
  const head = Offset(36, 12);
  const samples = <ShuttleTrailSample>[
    (point: start, speed: null, approximate: false, connected: false),
    (point: head, speed: 30, approximate: false, connected: true),
  ];

  test('colored trail stroke is slightly wider with and without a halo', () {
    final color = speedColors[1].withValues(alpha: 0.85);
    expect(
      (Canvas canvas) => paintShuttleTrail(canvas, samples, hasCurrent: false),
      paints..line(p1: start, p2: head, color: color, strokeWidth: 2),
    );
    expect(
      (Canvas canvas) => paintShuttleTrail(canvas, samples, hasCurrent: false, halo: true),
      paints
        ..line(p1: start, p2: head, strokeWidth: 5)
        ..line(p1: start, p2: head, color: color, strokeWidth: 3),
    );
  });

  test('the trail leaves the center of the shuttle marker visible', () async {
    const background = Color(0xFF26495A);
    const width = 48;
    const height = 24;
    final recorder = PictureRecorder();
    final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final canvas = Canvas(recorder, bounds)..drawColor(background, BlendMode.src);
    paintShuttleTrail(canvas, samples, hasCurrent: true, halo: true);
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);
    final image = picture.toImageSync(width, height);
    addTearDown(image.dispose);
    final pixels = (await image.toByteData())!;

    int channel(int x, int y) => pixels.getUint8((y * width + x) * 4);
    expect(channel(34, 12), 0x26);
    expect(channel(36, 7), greaterThan(180));
    expect(channel(20, 12), greaterThan(180));
  });
}
