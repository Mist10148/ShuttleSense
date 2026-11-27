import 'package:flutter/foundation.dart';

/// One bundled Denia sticker (Wonderboard deniaArt.ts): a picture (png or animated gif) or a
/// drawing (svg).
@immutable
class DeniaArt {
  const DeniaArt(this.name, this.asset);

  final String name;
  final String asset;

  bool get isSvg => asset.endsWith('.svg');
  bool get isGif => asset.endsWith('.gif');
}

/// The stickers, the per-variant sets and the short lines shown, rarely, in their place.
abstract final class DeniaArtCatalog {
  static const _pics = 'assets/skins/denia/pics';
  static const _props = 'assets/skins/denia';

  /// Every bundled sticker, in file order.
  static const all = [
    DeniaArt('denia-bubble-wand', '$_pics/01-bubble-wand.gif'),
    DeniaArt('denia-cake', '$_pics/02-cake.gif'),
    DeniaArt('denia-breakdown-peace', '$_pics/03-breakdown-peace.gif'),
    DeniaArt('denia-breakdown-snack', '$_pics/04-breakdown-snack.gif'),
    DeniaArt('denia-tongue-out', '$_pics/05-tongue-out.png'),
    DeniaArt('denia-smile', '$_pics/06-smile.png'),
    DeniaArt('denia-content', '$_pics/07-content.png'),
    DeniaArt('denia-blank-stare', '$_pics/08-blank-stare.png'),
    DeniaArt('denia-hug-plush', '$_pics/09-hug-plush.png'),
    DeniaArt('denia-flustered', '$_pics/10-flustered.gif'),
    DeniaArt('denia-desk-nap', '$_pics/11-desk-nap.gif'),
    DeniaArt('denia-evil-grin', '$_pics/12-evil-grin.gif'),
    DeniaArt('denia-drool-nap', '$_pics/13-drool-nap.png'),
    DeniaArt('denia-question-pout', '$_pics/14-question-pout.png'),
    DeniaArt('denia-cat-smile', '$_pics/15-cat-smile.png'),
    DeniaArt('denia-bunny-dizzy', '$_pics/16-bunny-dizzy.png'),
    DeniaArt('cat-plush', '$_props/01-cat-plush.svg'),
    DeniaArt('cat-plush-grumpy', '$_props/02-cat-plush-grumpy.svg'),
    DeniaArt('moon-clip', '$_props/03-moon-clip.svg'),
    DeniaArt('lace-bow', '$_props/04-lace-bow.svg'),
    DeniaArt('bubbles-and-stars', '$_props/05-bubbles-and-stars.svg'),
  ];

  static DeniaArt byName(String name) => all.firstWhere((a) => a.name == name);

  static List<DeniaArt> _by(List<String> names) => [for (final n in names) byName(n)];

  /// Light shows her cheerful pink side; Dark her Breakdown form, the evil grin and the sleepy
  /// ones most (some appear twice, so they come up more often).
  static List<DeniaArt> setFor({required bool dark}) => dark
      ? _by(const [
          'denia-breakdown-peace',
          'denia-evil-grin',
          'denia-breakdown-snack',
          'denia-desk-nap',
          'cat-plush-grumpy',
          'denia-drool-nap',
          'denia-breakdown-peace',
          'denia-blank-stare',
          'moon-clip',
          'denia-evil-grin',
          'denia-tongue-out',
          'denia-hug-plush',
          'denia-question-pout',
          'lace-bow',
          'denia-breakdown-snack',
          'denia-bunny-dizzy',
        ])
      : _by(const [
          'denia-bubble-wand',
          'denia-cake',
          'denia-tongue-out',
          'denia-smile',
          'denia-content',
          'denia-blank-stare',
          'denia-hug-plush',
          'denia-flustered',
          'denia-desk-nap',
          'denia-drool-nap',
          'denia-question-pout',
          'denia-cat-smile',
          'denia-bunny-dizzy',
          'cat-plush',
          'moon-clip',
          'lace-bow',
          'bubbles-and-stars',
        ]);

  /// The animated sticker in the middle of the switch animation.
  static DeniaArt switchArt({required bool dark}) =>
      byName(dark ? 'denia-breakdown-peace' : 'denia-bubble-wand');

  /// Short lines that appear, rarely, in place of a sticker.
  static const lines = [
    'Shh. Just keep it between us.',
    'Knock, knock!',
    'Five more minutes…',
    'Bubbles and baits',
    'The final act',
    'Sweet dreams ☆',
    'Hug the plush, finish the task',
    'Curtain up!',
    'Cake first, work later',
  ];
}
