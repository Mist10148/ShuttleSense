import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../features/skins/fx/backrooms_plan.dart';
import '../../features/skins/fx/denia_plan.dart';
import 'denia_synth.dart';
import 'skin_sounds.dart';
import 'wav_synth.dart';

void _nothing() {}

/// Plays the theme switch sounds with audioplayers. Every call is best effort: if the
/// platform cannot play (a browser that has not been interacted with, a missing codec), it
/// stays silent and never throws.
class AudioSkinSounds implements SkinSounds {
  final _live = <AudioPlayer, Timer?>{};

  static const _click = 'skins/backrooms/switch.mp3';
  static const _hum = 'skins/backrooms/hum.mp3';

  /// Starts [source] at [volume] and returns its stop.
  StopSound _play(Source source, double volume, {void Function(AudioPlayer p)? started}) {
    try {
      final p = AudioPlayer();
      _live[p] = null;
      p.onPlayerComplete.listen((_) => _release(p), onError: (_) => _release(p));
      unawaited(
        p
            .play(source, volume: volume)
            .then((_) => started?.call(p))
            .catchError((Object _) => _release(p)),
      );
      return () => _release(p);
    } catch (_) {
      return _nothing;
    }
  }

  void _release(AudioPlayer p) {
    if (!_live.containsKey(p)) return;
    _live.remove(p)?.cancel();
    unawaited(p.stop().catchError((Object _) {}).whenComplete(() => p.dispose()));
  }

  @override
  StopSound backroomsClick() => _play(AssetSource(_click), 0.8);

  /// The hum starts at 0.6 and fades linearly to silence over the clip (20 s if it cannot
  /// tell how long the clip is), checked every 100 ms.
  @override
  StopSound backroomsHum() => _play(
    AssetSource(_hum),
    0.6,
    started: (p) {
      if (!_live.containsKey(p)) return;
      final began = DateTime.now();
      Duration? length;
      unawaited(p.getDuration().then((d) => length = d).catchError((Object _) => null));
      _live[p] = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final dur = (length?.inMilliseconds ?? 0) > 0
            ? length!.inMilliseconds.toDouble()
            : BackroomsPlan.humFallbackMs.toDouble();
        final t = DateTime.now().difference(began).inMilliseconds.toDouble();
        if (t >= dur) return _release(p);
        unawaited(p.setVolume(BackroomsPlan.humVolume(t, dur)).catchError((Object _) {}));
      });
    },
  );

  /// Renders the score to a WAV (a few tens of ms) and plays it from memory.
  @override
  StopSound deniaScore(DeniaScore score) {
    try {
      final wav = deniaScoreWav(score, seed: DateTime.now().microsecond | 1);
      return _play(BytesSource(wav, mimeType: 'audio/wav'), 1);
    } catch (_) {
      return _nothing;
    }
  }

  bool _unlocked = false;

  /// Browsers allow sound once a page has been used, but only for playback started inside a
  /// user gesture. Playing 50 ms of silence on the first tap unlocks the page, so the first
  /// theme switch is heard (docs/THEMES.md). Other platforms never block sound.
  @override
  void unlock() {
    if (_unlocked || !kIsWeb) return;
    _unlocked = true;
    final silence = encodeWav(PcmBuffer(PcmBuffer.defaultRate, PcmBuffer.defaultRate ~/ 20));
    _play(BytesSource(silence, mimeType: 'audio/wav'), 0);
  }

  @override
  void stopAll() {
    for (final p in [..._live.keys]) {
      _release(p);
    }
  }
}
