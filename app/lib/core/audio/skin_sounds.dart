import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/skins/fx/denia_plan.dart';
import 'audio_skin_sounds.dart';

/// Stops a sound that is still playing. Safe to call more than once.
typedef StopSound = void Function();

void _nothing() {}

/// The sounds of the theme switches (docs/THEMES.md). Every call is best effort: on a
/// platform that cannot play, or with sound off, nothing happens and nothing throws.
abstract class SkinSounds {
  /// Backrooms: the switch click (Wonderboard switch.mp3).
  StopSound backroomsClick();

  /// Backrooms: the fluorescent hum, fading slowly to silence (Wonderboard hum.mp3).
  StopSound backroomsHum();

  /// Denia: the whoosh, chimes and bloops of one switch.
  StopSound deniaScore(DeniaScore score);

  /// Silences everything (a newer theme switch starts).
  void stopAll();
}

/// Plays nothing: tests, and platforms without audio.
class SilentSkinSounds implements SkinSounds {
  const SilentSkinSounds();

  @override
  StopSound backroomsClick() => _nothing;

  @override
  StopSound backroomsHum() => _nothing;

  @override
  StopSound deniaScore(DeniaScore score) => _nothing;

  @override
  void stopAll() {}
}

/// The app's player; tests override it with a fake or [SilentSkinSounds].
final skinSoundsProvider = Provider<SkinSounds>((ref) {
  final sounds = AudioSkinSounds();
  ref.onDispose(sounds.stopAll);
  return sounds;
});
