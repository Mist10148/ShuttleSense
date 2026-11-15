import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/watch/court_geometry.dart';

void main() {
  test('full court maps to singles and back under perspective', () {
    const full = [
      (x: 100.0, y: 690.0),
      (x: 1180.0, y: 670.0),
      (x: 850.0, y: 160.0),
      (x: 400.0, y: 180.0),
    ];
    final singles = fullToSingles(full)!;
    // Independently calculated with OpenCV getPerspectiveTransform.
    const expected = [
      (x: 177.40778, y: 688.5665),
      (x: 1094.3302, y: 671.5865),
      (x: 815.3412, y: 161.54039),
      (x: 433.22397, y: 178.52338),
    ];
    for (var i = 0; i < 4; i++) {
      expect(singles[i].x, closeTo(expected[i].x, 0.001));
      expect(singles[i].y, closeTo(expected[i].y, 0.001));
    }
    expect(singles[0].x, greaterThan(full[0].x));
    expect(singles[1].x, lessThan(full[1].x));
    expect(singles[2].x, lessThan(full[2].x));
    expect(singles[3].x, greaterThan(full[3].x));
    // A tilted baseline requires movement in both image axes, not linear x offsets.
    expect(singles[0].y, lessThan(full[0].y));
    final restored = singlesToFull(singles)!;
    for (var i = 0; i < 4; i++) {
      expect(restored[i].x, closeTo(full[i].x, 0.001));
      expect(restored[i].y, closeTo(full[i].y, 0.001));
    }
  });

  test('invalid and incomplete courts are rejected', () {
    expect(fullToSingles([]), isNull);
    expect(
      fullToSingles([(x: 0.0, y: 0.0), (x: 1.0, y: 1.0), (x: 0.0, y: 1.0), (x: 1.0, y: 0.0)]),
      isNull,
    );
  });
}
