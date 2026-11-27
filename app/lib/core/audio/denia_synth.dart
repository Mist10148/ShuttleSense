import 'dart:math' as math;
import 'dart:typed_data';

import '../../features/skins/fx/denia_plan.dart';
import 'wav_synth.dart';

/// Renders the sound of a Denia switch (Wonderboard deniaSound.ts, there made with Web Audio):
/// a whoosh of band-passed noise while the bubbles rise, a music-box arpeggio around the
/// change, and bubble bloops panned to each pop, through a soft limiter and a short reverb.
PcmBuffer renderDeniaScore(
  DeniaScore score, {
  int sampleRate = PcmBuffer.defaultRate,
  int seed = 1,
}) {
  // the score, then the reverb's tail
  final frames = ((score.lengthMs + 1400) / 1000 * sampleRate).ceil();
  final dry = PcmBuffer(sampleRate, frames), send = PcmBuffer(sampleRate, frames);
  final rand = math.Random(seed);
  const t0 = 0.03;

  _whoosh(dry, send, t0 + score.whoosh.at / 1000, score.whoosh, rand);
  for (final n in score.chimes) {
    _chime(dry, send, t0 + n.at / 1000, n.freq, n.vol);
  }
  for (final p in score.pops) {
    _bloop(dry, send, t0 + p.at / 1000, p.freq, p.pan, rand);
  }

  addReverb(send, dry, seconds: 1.6, wet: 0.32);
  for (var i = 0; i < frames; i++) {
    dry.left[i] *= 0.9;
    dry.right[i] *= 0.9;
  }
  limit(dry);
  return dry;
}

/// The score as a WAV file.
Uint8List deniaScoreWav(DeniaScore score, {int seed = 1}) =>
    encodeWav(renderDeniaScore(score, seed: seed));

void _mix(PcmBuffer dry, PcmBuffer send, int i, double v, double sendLevel, [double pan = 0]) {
  dry.add(i, v, pan);
  if (sendLevel > 0) send.add(i, v * sendLevel, pan);
}

/// Filtered noise sweeping from [Whoosh.from] to [Whoosh.to] Hz (Q 1.1) while it swells and
/// fades.
void _whoosh(PcmBuffer dry, PcmBuffer send, double t, Whoosh w, math.Random rand) {
  final sr = dry.sampleRate, d = w.dur / 1000;
  final bp = Biquad.bandpass(sr, w.from, 1.1);
  final start = dry.frameAt(t), end = dry.frameAt(t + d + 0.3);
  for (var i = start; i < end; i++) {
    final s = i / sr;
    if ((i - start) % 32 == 0) bp.setFrequency(expRamp(s, t, w.from, t + d, w.to));
    final g = s < t + d * 0.55
        ? expRamp(s, t, 0.0001, t + d * 0.55, w.vol)
        : expRamp(s, t + d * 0.55, w.vol, t + d + 0.25, 0.0001);
    _mix(dry, send, i, bp.process(rand.nextDouble() * 2 - 1) * g, 0.5);
  }
}

/// One music-box note: a sine with two quieter partials, a quick attack and a long ring.
void _chime(PcmBuffer dry, PcmBuffer send, double t, double freq, double vol) {
  final sr = dry.sampleRate;
  for (final (k, a, ring) in const [(1.0, 1.0, 1.5), (2.01, 0.32, 0.7), (3.98, 0.12, 0.35)]) {
    final f = freq * k;
    if (f >= sr / 2) continue;
    final start = dry.frameAt(t), end = dry.frameAt(t + ring + 0.05);
    for (var i = start; i < end; i++) {
      final s = i / sr;
      final g = s < t + 0.006
          ? expRamp(s, t, 0.0001, t + 0.006, vol * a)
          : expRamp(s, t + 0.006, vol * a, t + ring, 0.0001);
      _mix(dry, send, i, math.sin(2 * math.pi * f * (s - t)) * g, 0.6);
    }
  }
}

/// One bubble: a sine chirping up ×2.3 in 55 ms (what a real bubble does) and a tiny click of
/// high-passed noise, panned to where it popped.
void _bloop(PcmBuffer dry, PcmBuffer send, double t, double freq, double pan, math.Random rand) {
  final sr = dry.sampleRate;
  final detune = 1 + (rand.nextDouble() - 0.5) * 0.06;
  final f0 = freq * detune, f1 = freq * 2.3 * detune;
  var phase = 0.0;
  final start = dry.frameAt(t), end = dry.frameAt(t + 0.12);
  for (var i = start; i < end; i++) {
    final s = i / sr;
    phase += 2 * math.pi * expRamp(s, t, f0, t + 0.055, f1) / sr;
    final g = s < t + 0.004
        ? expRamp(s, t, 0.0001, t + 0.004, 0.2)
        : expRamp(s, t + 0.004, 0.2, t + 0.1, 0.0001);
    _mix(dry, send, i, math.sin(phase) * g, 0.35, pan);
  }
  final hp = Biquad.highpass(sr, 2500);
  final clickEnd = dry.frameAt(t + 0.03);
  for (var i = start; i < clickEnd; i++) {
    final g = expRamp(i / sr, t, 0.05, t + 0.02, 0.0001);
    _mix(dry, send, i, hp.process(rand.nextDouble() * 2 - 1) * g, 0.35, pan);
  }
}
