// The theme switch synthesizer (docs/THEMES.md): valid WAV files, no clipping, filters that
// pass what they should, and Denia's whoosh sweeping up for Light and down for Dark.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/audio/denia_synth.dart';
import 'package:shuttlesense_app/core/audio/wav_synth.dart';
import 'package:shuttlesense_app/features/skins/fx/denia_plan.dart';

String _ascii(Uint8List b, int at, int n) => String.fromCharCodes(b.sublist(at, at + n));

/// Zero crossings per second of the left channel between [from] and [to] seconds.
double _zcr(PcmBuffer b, double from, double to) {
  final s = b.frameAt(from), e = b.frameAt(to);
  var n = 0;
  for (var i = s + 1; i < e; i++) {
    if ((b.left[i - 1] < 0) != (b.left[i] < 0)) n++;
  }
  return n / (to - from);
}

double _rms(List<double> x) => math.sqrt(x.fold(0.0, (a, v) => a + v * v) / x.length);

void main() {
  test('a WAV file has a valid header and every sample', () {
    final b = PcmBuffer(24000, 2400);
    b.add(10, 0.5, -1);
    b.add(11, 2); // clamps
    final wav = encodeWav(b);
    final d = ByteData.sublistView(wav);
    expect(_ascii(wav, 0, 4), 'RIFF');
    expect(_ascii(wav, 8, 4), 'WAVE');
    expect(_ascii(wav, 36, 4), 'data');
    expect(d.getUint16(22, Endian.little), 2);
    expect(d.getUint32(24, Endian.little), 24000);
    expect(d.getUint32(40, Endian.little), 2400 * 4);
    expect(wav.length, 44 + 2400 * 4);
    expect(d.getInt16(44 + 10 * 4, Endian.little), closeTo(32767 * 0.5, 2)); // panned hard left
    expect(d.getInt16(44 + 10 * 4 + 2, Endian.little).abs(), lessThan(2));
    expect(d.getInt16(44 + 11 * 4, Endian.little), lessThanOrEqualTo(32767));
  });

  test('the exponential ramp behaves like Web Audio', () {
    expect(expRamp(0, 1, 0.1, 2, 1), 0.1);
    expect(expRamp(1.5, 1, 0.1, 2, 1), closeTo(math.sqrt(0.1), 1e-9));
    expect(expRamp(3, 1, 0.1, 2, 1), 1);
  });

  test('a band-pass keeps its centre and drops what is far from it', () {
    double through(double freq) {
      final bp = Biquad.bandpass(24000, 1000, 1.1);
      final out = [
        for (var i = 0; i < 4800; i++) bp.process(math.sin(2 * math.pi * freq * i / 24000)),
      ];
      return _rms(out.sublist(2400));
    }

    expect(through(1000), greaterThan(0.6));
    expect(through(100), lessThan(0.15));
    expect(through(8000), lessThan(0.15));
  });

  test('the limiter keeps the peak at 0.9 or below', () {
    final b = PcmBuffer(24000, 100);
    for (var i = 0; i < 100; i++) {
      b.add(i, 3 * math.sin(i / 5));
    }
    limit(b);
    expect(b.peak, lessThanOrEqualTo(0.9 + 1e-9));
  });

  test('every Denia switch renders, has sound, and never clips', () {
    for (final kind in DeniaSwitchKind.values) {
      final score = deniaScore(kind, deniaBubbles(kind.plan, 3));
      final b = renderDeniaScore(score, seed: 3);
      expect(b.seconds, greaterThan(score.lengthMs / 1000));
      expect(b.peak, inInclusiveRange(0.01, 0.9 + 1e-9), reason: kind.name);
      final wav = deniaScoreWav(score, seed: 3);
      expect(wav.length, 44 + b.frames * 4);
    }
  });

  test('the whoosh sweeps up for Light and down for Dark', () {
    DeniaScore whooshOnly(DeniaSwitchKind k) {
      final s = deniaScore(k, const []);
      return DeniaScore(s.whoosh, const [], const []);
    }

    final up = renderDeniaScore(whooshOnly(DeniaSwitchKind.enterLight));
    final down = renderDeniaScore(whooshOnly(DeniaSwitchKind.enterDark));
    // the whoosh lasts 0.78 s from 0.03 s
    expect(_zcr(up, 0.55, 0.8), greaterThan(_zcr(up, 0.1, 0.3) * 1.5));
    expect(_zcr(down, 0.1, 0.3), greaterThan(_zcr(down, 0.55, 0.8) * 1.5));
  });

  test('a single chime sounds at its pitch', () {
    final b = renderDeniaScore(
      const DeniaScore(Whoosh(at: 0, dur: 300, from: 350, to: 351, vol: 0.0001), [
        ChimeNote(0, 659.25, 0.16),
      ], []),
    );
    // mostly the fundamental: about two crossings per cycle
    expect(_zcr(b, 0.05, 0.4), closeTo(2 * 659.25, 200));
  });
}
