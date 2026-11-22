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
}
