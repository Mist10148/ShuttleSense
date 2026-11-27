import 'dart:math' as math;
import 'dart:typed_data';

/// A stereo sound being built, as floating-point samples in -1..1 (docs/THEMES.md). Pure Dart,
/// so it runs and is tested the same on every platform; [encodeWav] turns it into a file the
/// player can take as bytes.
class PcmBuffer {
  PcmBuffer(this.sampleRate, int frames) : left = Float64List(frames), right = Float64List(frames);

  /// Low enough to render fast, high enough for the highest partial (about 6.6 kHz).
  static const int defaultRate = 24000;

  final int sampleRate;
  final Float64List left;
  final Float64List right;

  int get frames => left.length;
  double get seconds => frames / sampleRate;

  /// The frame at [seconds], clamped to the buffer.
  int frameAt(double seconds) => (seconds * sampleRate).round().clamp(0, frames);

  /// Adds a mono [sample] at [frame], panned by [pan] (-1 left .. 1 right, equal power).
  void add(int frame, double sample, [double pan = 0]) {
    if (frame < 0 || frame >= frames) return;
    final a = (pan.clamp(-1.0, 1.0) + 1) * math.pi / 4;
    left[frame] += sample * math.cos(a);
    right[frame] += sample * math.sin(a);
  }

  /// The loudest sample.
  double get peak {
    var p = 0.0;
    for (var i = 0; i < frames; i++) {
      p = math.max(p, math.max(left[i].abs(), right[i].abs()));
    }
    return p;
  }
}

/// Web Audio's exponentialRampToValueAtTime: from [v0] at [t0] to [v1] at [t1] (seconds).
/// Before [t0] it is [v0]; after [t1] it is [v1].
double expRamp(double t, double t0, double v0, double t1, double v1) {
  if (t <= t0) return v0;
  if (t >= t1) return v1;
  return v0 * math.pow(v1 / v0, (t - t0) / (t1 - t0));
}

/// A biquad filter (Robert Bristow-Johnson's cookbook), as in Web Audio's BiquadFilterNode.
class Biquad {
  Biquad.bandpass(this.sampleRate, double freq, this.q) : _type = _Type.bandpass {
    setFrequency(freq);
  }

  Biquad.highpass(this.sampleRate, double freq, [this.q = math.sqrt1_2]) : _type = _Type.highpass {
    setFrequency(freq);
  }

  final int sampleRate;
  final double q;
  final _Type _type;
  double _b0 = 0, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  void setFrequency(double freq) {
    final f = freq.clamp(10.0, sampleRate / 2 - 10);
    final w = 2 * math.pi * f / sampleRate, cw = math.cos(w), alpha = math.sin(w) / (2 * q);
    final a0 = 1 + alpha;
    switch (_type) {
      case _Type.bandpass: // constant 0 dB peak gain
        _b0 = alpha / a0;
        _b1 = 0;
        _b2 = -alpha / a0;
      case _Type.highpass:
        _b0 = (1 + cw) / 2 / a0;
        _b1 = -(1 + cw) / a0;
        _b2 = (1 + cw) / 2 / a0;
    }
    _a1 = -2 * cw / a0;
    _a2 = (1 - alpha) / a0;
  }

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

enum _Type { bandpass, highpass }

/// A small, soft room (Schroeder: four combs into two all-passes per channel), standing in for
/// Wonderboard's 1.6 s convolution reverb, which is too slow to compute here. [send] holds
/// what goes into the reverb; the wet result is mixed into [out] at [wet].
void addReverb(PcmBuffer send, PcmBuffer out, {double seconds = 1.6, double wet = 0.32}) {
  final sr = send.sampleRate;
  const combMs = [29.7, 37.1, 41.1, 43.7], allMs = [5.0, 1.7];
  for (final (ch, src, dst) in [(0, send.left, out.left), (1, send.right, out.right)]) {
    final n = src.length;
    final mixed = Float64List(n);
    for (final ms in combMs) {
      final d = ((ms + ch * 1.3) / 1000 * sr).round();
      // feedback for a 60 dB decay over [seconds]
      final g = math.pow(10, -3 * (d / sr) / seconds).toDouble();
      final buf = Float64List(d);
      var idx = 0;
      for (var i = 0; i < n; i++) {
        final y = buf[idx];
        buf[idx] = src[i] + y * g;
        idx = (idx + 1) % d;
        mixed[i] += y / combMs.length;
      }
    }
    var x = mixed;
    for (final ms in allMs) {
      final d = (ms / 1000 * sr).round();
      final buf = Float64List(d);
      final y = Float64List(n);
      var idx = 0;
      for (var i = 0; i < n; i++) {
        final b = buf[idx];
        final v = x[i] + b * 0.5;
        y[i] = b - v * 0.5;
        buf[idx] = v;
        idx = (idx + 1) % d;
      }
      x = y;
    }
    for (var i = 0; i < n; i++) {
      dst[i] += x[i] * wet;
    }
  }
}

/// Keeps the mix from clipping, like Wonderboard's compressor: a gentle curve above [knee]
/// and a final scale so the peak is at most [ceiling].
void limit(PcmBuffer b, {double knee = 0.5, double ceiling = 0.9}) {
  double soft(double x) {
    final a = x.abs();
    if (a <= knee) return x;
    final over = (a - knee) / (1 - knee);
    return x.sign * (knee + (1 - knee) * (over / (1 + over)));
  }

  for (var i = 0; i < b.frames; i++) {
    b.left[i] = soft(b.left[i]);
    b.right[i] = soft(b.right[i]);
  }
  final p = b.peak;
  if (p > ceiling) {
    final k = ceiling / p;
    for (var i = 0; i < b.frames; i++) {
      b.left[i] *= k;
      b.right[i] *= k;
    }
  }
}

/// A 16-bit stereo PCM WAV file of [b].
Uint8List encodeWav(PcmBuffer b) {
  const channels = 2, bytesPerSample = 2;
  final dataLen = b.frames * channels * bytesPerSample;
  final out = ByteData(44 + dataLen);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  out.setUint32(4, 36 + dataLen, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, channels, Endian.little);
  out.setUint32(24, b.sampleRate, Endian.little);
  out.setUint32(28, b.sampleRate * channels * bytesPerSample, Endian.little);
  out.setUint16(32, channels * bytesPerSample, Endian.little);
  out.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  out.setUint32(40, dataLen, Endian.little);
  var at = 44;
  for (var i = 0; i < b.frames; i++) {
    for (final s in [b.left[i], b.right[i]]) {
      out.setInt16(at, (s.clamp(-1.0, 1.0) * 32767).round(), Endian.little);
      at += 2;
    }
  }
  return out.buffer.asUint8List();
}
