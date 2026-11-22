import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/results/widgets/court_minimap.dart';

/// The app draws its heatmap from the record's positions (HeatGrid) instead of fetching the
/// backend's heatmap.json; these fixtures are that file for the golden records, made with
/// backend/shuttlesense/analytics/heatmap.py build_heatmap (landings left out). Regenerate
/// them when the backend's method changes; this test then says whether the app still
/// draws the same picture.
Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  for (final name in ['golden_record', 'golden_record_doubles']) {
    group(name, () {
      final record = ClipRecord.fromJson(_json('test/fixtures/$name.json'));
      final backend = _json('test/fixtures/${name}_heatmap.json');
      final grid = HeatGrid.fromRecord(record);

      test('the grid has the backend\'s court, cells and origin', () {
        expect(backend['court_size_m'], [kCourtWidthM, kCourtLengthM]);
        expect(backend['cell_m'], kHeatCellM);
        expect(backend['origin_m'], [-HeatGrid.margin, -HeatGrid.margin]);
        expect(backend['cols'], HeatGrid.cols);
        expect(backend['rows'], HeatGrid.rows);
        final sigma = backend['sigma_m'] as Map<String, dynamic>;
        expect(sigma['near_baseline'], kHeatSigmaNearM);
        expect(sigma['far_baseline'], kHeatSigmaFarM);
      });

      for (final side in ['near', 'far']) {
        test('$side: same seconds, same busiest cell, cells within 2% of the peak', () {
          final player = (backend['players'] as Map<String, dynamic>)[side] as Map<String, dynamic>;
          final rows = (player['grid'] as List).cast<List<dynamic>>();
          final theirs = [
            for (final row in rows)
              for (final v in row) (v as num).toDouble(),
          ];
          final ours = side == 'near' ? grid.near : grid.far;
          expect(ours.length, theirs.length);

          // Total time: every frame in play adds 1 / fps wherever its kernel lands.
          final total = ours.fold<double>(0, (a, b) => a + b);
          expect(total, closeTo((player['seconds'] as num).toDouble(), 0.01));

          // The busiest cell is the same cell (its centre, in metres).
          final peak = ours.reduce(math.max);
          final o = HeatGrid.cellOrigin(ours.indexOf(peak));
          final centre = [o.x + kHeatCellM / 2, o.y + kHeatCellM / 2];
          final theirPeak = (player['peak_m'] as List).cast<num>();
          expect(centre[0], closeTo(theirPeak[0].toDouble(), 1e-6));
          expect(centre[1], closeTo(theirPeak[1].toDouble(), 1e-6));

          // Every cell: the app cuts each kernel at 3 sigma, the backend does not.
          var worst = 0.0;
          for (var i = 0; i < ours.length; i++) {
            worst = math.max(worst, (ours[i] - theirs[i]).abs());
          }
          expect(worst / peak, lessThan(0.02));
        });
      }
    });
  }
}
