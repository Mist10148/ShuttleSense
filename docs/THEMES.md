# Themes

> **Experimental.** This work lives on the `experimental-themes` branch. It edits a few lines of the theme builder that Delariman and Limpin wrote, so it needs a review from the lead UI/UX developer (Limpin) before anything here is merged (CONTRIBUTING.md). Decision: D49.

ShuttleSense has one look, the tactile (neumorphic) design, in light and dark. This page records three more themes that sit on top of it. They are chosen in **Settings > Theme**:

| Theme | Brightness | Mood |
| --- | --- | --- |
| **Classic** | system / light / dark | the existing tactile look (unchanged) |
| **Backrooms** | light | an endless office of yellowed wallpaper under humming fluorescent lights |
| **Denia (Light)** | light | pink "Stagecraft": soft stage light, bubbles and stars, lace |
| **Denia (Dark)** | dark | purple "Breakdown": violet over near-black with pink glints |

The themes come from Wonderboard (the author's endless-canvas board app), where the same three themes exist. This page lists what was taken from it and how it maps to Flutter.

## Ground rules

1. **The tactile recipe does not change.** Raised plates, sunken wells and key caps keep the same light direction (top left), the same dual shadows, the same radii and the same motion. A theme only changes the *tones* the recipe is drawn with. Every theme therefore fills the full set of tactile tokens (`TactileTokens`, `DepthTheme`), not just a colour scheme.
2. **Data colours stay put.** Line calls (in, out, uncertain), player colours and marks painted on video keep their Classic values (PRD design principles, D27). A theme may never make an OUT look like an IN.
3. **Readable first.** Body and secondary text keep 4.5:1 against every surface they sit on, and key UI edges (accents, rims, focus) keep 3:1 (WCAG 2.2 SC 1.4.3 and 1.4.11). `test/skin_tokens_test.dart` holds every theme to this.
4. **Decoration never takes input.** Wallpaper, lighting, grain and stickers are painted behind every page, wrapped in `IgnorePointer` and hidden from screen readers. Cards, keys, wells, bars and dialogs keep their solid tactile fills over them. Page titles printed straight on the wall are held to 4.5:1 against the wall, which is why the Backrooms floor shadow is lighter than Wonderboard's.
5. **Motion and sound are optional.** Switch animations honour reduced motion (`MediaQuery.disableAnimations`) and a setting. Sounds have their own setting. With either off, the theme simply changes.

## Architecture

```text
AppSkin (enum, saved as ui.skin) ──► SkinBundle (const tokens per theme)
        │                                 │
        │                                 ▼
        │                     AppTheme.fromBundle(...)  ──► ThemeData
        │                                 │                 (ColorScheme, component themes,
        │                                 │                  AppPalette, TactileTokens, DepthTheme,
        │                                 │                  AnalysisColors, StatusColors,
        │                                 │                  PlayerColors, SkinDecor)
        │                                 ▼
        │                MaterialApp.builder:
        └──────────────► SkinFxHost (switch overlay, last tap)
                           └─ SkinScope ─► SkinBackdrop (wallpaper / pattern, stickers,
                                │                        light, grain, lace)
                                └─ Theme with clear page fills ─► the router's pages
```

- `app/lib/core/theme/app_skin.dart`: the `AppSkin` enum, the saved choice (`ui.skin`) and the extras (`ui.skinFx.motion`, `.sound`, `.stickers`, `.stickerStrength`).
- `app/lib/core/theme/skins/`: one const bundle per theme (`backrooms_tokens.dart`, `denia_tokens.dart`), `SkinDecor` (the extension that tells decoration what to paint), the sticker catalogue (`denia_art.dart`) and `skin_theme.dart` (`bundleFor`, `themesFor`, `skinTheme`).
- `app/lib/shared/widgets/skin/`: the painters (`backrooms_wallpaper`, `backrooms_grain`, `backrooms_light`, `denia_pattern`, `denia_stage_light`, `denia_lace`, `denia_stickers`), `SkinBackdrop` and `SkinScope`.
- `app/lib/features/skins/fx/`: the timing plans, the switch controller (`skin_switch.dart`), the host and the Backrooms and Denia overlays.
- `app/lib/core/audio/`: `wav_synth.dart` (a small pure-Dart synthesizer and WAV writer), `denia_synth.dart` (the Denia score), `skin_sounds.dart` (the interface) and `audio_skin_sounds.dart` (audioplayers).
- `app/lib/features/settings/widgets/theme_picker_card.dart`: the Theme card, with a link to the gallery.
- `app/lib/features/styleguide/theme_gallery_screen.dart`: `/styleguide/themes`, every theme side by side.

**How the backdrop shows.** In Classic, every page is opaque: the shell's chassis panel fills the window on wide screens, and Scaffolds fill it on phones. For a decorated theme, `SkinScope` paints the backdrop under the router and gives the pages a `Theme` where those page-sized fills are clear: the scaffold background, `TactileTokens.chassisTop/Bottom`, `AppPalette.canvas/page/canvasGlows`, and the shell's popover shadow, which would darken the whole wall under a clear panel. The bottom navigation bar, cards, keys and dialogs keep the colours baked into their component themes, so they stay solid.

**Lines owned by teammates that changed** (they need a review from the lead UI/UX developer):
- `AppTheme._build` (`app_theme.dart`) gains optional `tactile`, `analysis`, `depth` and `decor` parameters. The three lines that chose those by brightness now fall back to that choice, so Classic is unchanged. `fromBundle` is new.
- `app.dart` lines 20–21 (the high-contrast themes) now come from `themesFor`.
- Two lines are added to `SettingsScreen` (the Theme card).

Everything else is new files. `surfaces.dart`, `depth.dart` and `tactile.dart` are untouched.

## Backrooms

Reference: Wonderboard `src/style.css:4-8`, `src/canvas/cropAndZoom.css:20-58`, `src/fx/backroomsSwitch.ts`, `src/fx/backroomsPlan.ts`, `docs/themes/backrooms.md`, notes 14 and 20.

**Palette** (Wonderboard tokens, then the tactile tones derived from them):

| Role | Value | Notes |
| --- | --- | --- |
| page / canvas | `#B6B461` | the wallpaper base |
| card (raised top) | `#D4D291` | Wonderboard `--card` |
| border / dot | `#8C8A46` | |
| text | `#24230D` | |
| muted text | `#403E14` | ShuttleSense uses `#33310F` / `#3A3812` so it keeps 4.5:1 on the wall and wells |
| accent | `#5A5712` | primary keys, focus |
| line colour | `#4A4720` | |
| plates | `#DEDC9F` → `#CFCD8A` | raised top and bottom |
| wells | `#C2C076` | recess |
| highlight / shade | `#F4F1C0` at 80% / `#5E5B22` at 70% | the neumorphic pair |

The neumorphic highlight is a warm, paper-pale yellow and the shade is a dark olive-brown, so plates read as moulded from the same damp plaster as the walls.

**Wallpaper.** An SVG tile, 360×542 drawn at 270×406.5 (75%): base `#B6B461`; two vertical stripes 54 wide at x=63 and x=243 in `#A59F4A`; in each stripe, 10×45 dashes at x=85 and x=265, alternating `#98923F` / `#B3AF5B`, every 180.67 (y = −15.67, 29.33, 165, 210, 345.67, 390.67, …); chevron hexagons in `#9A9340`: `180,248 235,310 235,395 180,336 125,395 125,310` and `180,369 235,432 235,463 180,402 125,463 125,432` in the middle column, the same shapes half a tile up and down at x=0 and x=360.

**Ceiling light.** Fixed to the window over the wallpaper (Wonderboard, then what ShuttleSense uses):
- `radial-gradient(ellipse 62% 48% at 50% -6%, rgba(255,252,206,.46), rgba(255,252,206,.18) 48%, transparent 78%)`: the same.
- `linear-gradient(to bottom, transparent 32%, rgba(30,28,4,.18) 66%, rgba(30,28,4,.46) 100%)`: the floor darkens to `.12` and `.22` here.
- `radial-gradient(ellipse 130% 105% at 50% 22%, transparent 52%, rgba(38,36,6,.30) 100%)`: the vignette reaches `.20` here.

The floor and vignette are lighter because ShuttleSense prints page titles straight on the wall, and those must keep 4.5:1.

**Plaster grain.** Wonderboard lays two layers of SVG fractal noise on its ribbon and side panel: a pale warm speck layer (`feTurbulence` 0.45, 2 octaves, ≈ `rgb(255,250,199)`) and a dark olive one (0.7, 3 octaves, ≈ `rgb(51,48,8)`). ShuttleSense has no bare navigation panels (they are tactile plates), so the grain sits on the wall itself. It is a 160 px tile of seeded specks (seeds 5 and 11, as in Wonderboard), recorded once.

**Switch animation** (into Backrooms only):

| t (ms) | What happens |
| --- | --- |
| 0 | `switch.mp3` at 0.8, the screen goes black |
| 150 | the theme changes behind the cover |
| 2150 | the Backrooms logo appears |
| 4150 | the cover lifts; `switch.mp3` again; `hum.mp3` starts at 0.6 and fades linearly to silence over its length (20 s if unknown) |
| 4150–9150 | the logo fades out, linear |

From Settings the animation starts 1000 ms after the tap, so the user sees the choice land first. A newer theme switch cancels it and stops the hum.

## Denia (Light) and Denia (Dark)

Reference: Wonderboard `src/theme/denia.css`, `src/canvas/decor.ts:130-168`, `src/theme/deniaArt.ts`, `src/fx/deniaSwitch.ts`, `src/fx/deniaPlan.ts`, `src/fx/deniaSound.ts`, `docs/themes/denia.md`, notes 31–33 and 50.

Denia is a character from *Wuthering Waves*. Light borrows her pink "Stagecraft" side (cute, on stage) and Dark her purple "Breakdown" side (mysterious, violet over near-black).

**Palette:**

| Token | Light | Dark |
| --- | --- | --- |
| page / canvas | `#F9E8EF` | `#140D1C` |
| side (shell) | `#FDF3F7` | `#1C1228` |
| card | `#FFFFFF` | `#251833` |
| border | `#E9BFD0` | `#43305A` |
| text | `#2A1A24` | `#F3E9F7` |
| muted | `#86576D` | `#B9A3CB` |
| accent | `#C2255C` | `#C98BFF` |
| second accent | — | `#FF6FAE` |
| focus (her gem) | `#3B82C4` | `#8EC9F2` |
| gold | `#B8862F` | `#E2C06F` |
| dot | `#EFC6D6` | `#2D1F3D` |

**Stage light**, fixed to the window. Light: a white glow from above (`ellipse 72% 52% at 50% -10%`, `.78 → .25 at 46% → 0 at 76%`), a pink edge vignette (`rgba(226,140,182,.24)` from 54%) and a pale-blue floor tint (`rgba(184,221,243,.20)` from 60%). Dark: a violet glow (`rgba(201,139,255,.20 → .07)`), a near-black vignette (`rgba(4,2,10,.55)` from 50%) and a blue floor tint (`rgba(60,110,190,.10)`).

**Pattern**: a 240 px tile of soap bubbles and stars. The exact positions are in `denia_pattern.dart`, taken from decor.ts.

**Lace**: a row of scallops (2.6 px dots every 11 px, 5 px tall) hanging from the top edge of the window, in the border colour. `DeniaLace` can also be placed under any header.

**Stickers**: the 16 Denia pictures and the 5 drawn props from Wonderboard, scattered on a hashed grid.
- **Grid:** cells of 340, 70% filled. Stickers are 104–168 tall and tilted up to ±0.24 rad. Centres move at most 60 px, so stickers stay at least 220 apart (Wonderboard asks for 190).
- **Opacity:** `.35 / .65 / .95` for Faint / Normal / Strong, ×0.85 in Dark.
- **Quote pills:** about one cell in 28 shows one of Wonderboard's short lines in a pill instead.
- **Sets:** Light and Dark use different sticker sets (`DeniaArtCatalog.setFor`).
- **Still:** GIFs hold their first frame, as on Wonderboard's canvas.
- **Die-cut rim:** the props' SVGs draw their white rim and drop shadow with a filter (alpha dilated by 5, then a shadow blurred 2.2 and moved down 2.5 in `#3a1f33` at 28%), which `flutter_svg` skips. `DieCutRim` (`denia_stickers.dart`) draws the shape again instead: once tinted and blurred as the shadow, twelve times in white on a ring of the same radius, then itself, all scaled from the 220 viewBox.

**Switch animation**:

| Switch | Bubbles | Theme changes (ms) | Pops (ms) | Ends (ms) |
| --- | --- | --- | --- | --- |
| into Denia | 34 | 620 | 820–1500 | 1800 |
| Light ↔ Dark | 16 | 260 | 380–820 | 1100 |
| leaving Denia | 14 | 160 | 300–680 | 860 |

A colour iris grows from where the user tapped and covers the screen when the theme changes. Iridescent bubbles rise and pop into a ring and droplets. Four-point sparkles twinkle. A card bounces in with "Denia · Stagecraft" or "Denia · Breakdown".

**Sound.** Wonderboard makes this score live with Web Audio. ShuttleSense renders it in pure Dart (`denia_synth.dart`) to a 24 kHz stereo WAV when the switch starts, then plays it from memory. The score has three layers:
- **Whoosh:** band-passed noise, Q 1.1, sweeping 350→3200 Hz (rising) for Light and 2600→500 Hz (falling) for Dark.
- **Chimes:** a music-box arpeggio around the moment the theme changes. Light rises through E major (659.25–1661.22 Hz), Dark falls through G minor (1174.66–392 Hz). Partials are ×1, ×2.01 and ×3.98.
- **Bloops:** a sine chirping up ×2.3 in 55 ms, plus a click of high-passed noise, panned to each pop.

Everything passes through a soft limiter and a 1.6 s reverb at 0.32 wet. Wonderboard's reverb is a convolution, which is too slow in Dart, so a Schroeder reverb stands in.

## Light and Dark

Settings > Appearance and the sun/moon button on the navigation rail set Light, Dark or System. Classic follows it directly. Denia has a light and a dark side, so the same switch moves it between Denia (Light) and Denia (Dark), with the usual switch animation; System follows the device's brightness. Backrooms is light only: choosing Dark there keeps Backrooms and shows a short note (D54). The listener lives in `SkinFxHost`, so the rail button itself is unchanged.

## Accessibility and performance

- **Reduced motion, or "Switch animation" off:** no overlay and no sound; the theme changes at once.
- **"Switch sound" off:** the animation plays silently.
- **High contrast:** every theme collapses to flat borders, as Classic does (`TactileTokens.asFlat`), and the decoration is hidden.
- **Painting cost:** tiles (wallpaper, grain, pattern) are recorded once as pictures and drawn behind a `RepaintBoundary`, so the backdrop does not repaint when pages scroll. Stickers hold still.
- **Cancelling:** only one switch runs at a time. A newer change cancels the running one and stops its sound, including the Backrooms hum.
- **First sound on the web:** browsers block sound until the page has been used, and only allow playback that starts inside a user gesture. The first tap anywhere plays 50 ms of silence (`SkinSounds.unlock`), so the first switch is heard.
- **Route transitions:** with page fills clear, a page pushed over another shows both for the length of the transition. The wide layout already worked this way.

## Asset provenance

| Asset | Source | Licence / status |
| --- | --- | --- |
| `assets/skins/backrooms/logo.png`, `switch.mp3`, `hum.mp3` | Wonderboard `src/assets/backrooms/` | carried over from Wonderboard as is |
| `assets/skins/denia/0*-*.svg` (cat plush, grumpy plush, moon clip, lace bow, bubbles and stars) | Wonderboard `src/assets/denia/`, drawn for Wonderboard | original drawings |
| `assets/skins/denia/pics/*` (16 pictures) | Wonderboard `src/assets/denia/pics/`, made into stickers from the author's own pictures | **third-party character art (Wuthering Waves) and fan art.** Wonderboard's design notes say builds containing them must not be published. They are in this repository by the author's choice. Remove them before any public release. |

## Adding a theme

1. Add a value to `AppSkin` (label, brightness, family).
2. Write a const `SkinBundle`: all of `AppPalette`, `TactileTokens`, `DepthTheme`, `AnalysisColors` and `SkinDecor`. Keep `page` and `bg` different and neither pure white nor pure black, or the neumorphic highlight and shadow vanish.
3. Add it to the contrast loops in `test/skin_tokens_test.dart`.
4. Optional: a backdrop painter and a switch animation.

## Tests

| File | What it holds |
| --- | --- |
| `test/skin_settings_test.dart` | the saved theme and extras, defaults and fallbacks |
| `test/skin_tokens_test.dart` | 4.5:1 text and 3:1 edges on every surface of every theme, sliders at 3:1 on cards, distinct page and plate tones, Classic data colours, every extension registered, flat in high contrast |
| `test/skin_backdrop_test.dart` | each backdrop at phone, tablet and laptop sizes, sticker placement, the die-cut rim, the settings and high contrast, which fills turn clear |
| `test/skin_fx_test.dart` | plans and scores against Wonderboard's, which animation each change gets, the moment the theme changes, the Settings delay, cancelling, reduced motion, motion and sound off, the first-tap sound unlock |
| `test/wav_synth_test.dart` | WAV headers, the ramp and filters, no clipping, whoosh direction, chime pitch |
| `test/theme_picker_test.dart` | choosing and saving a theme, the extras, Settings in every theme at every size |
| `test/skin_mode_follow_test.dart` | Light/Dark moves Denia between its sides, Backrooms stays with a note, Classic is left alone |
| `test/theme_gallery_test.dart` | the gallery draws every theme at every size, with labelled panels |

`pumpScreen` takes an optional `skin:` to render any screen in a theme.

## Known limits

- `ui/depth.dart` and `shared/widgets/tactile.dart` hardcode some shadow alphas by brightness. Every theme maps to light or dark, so they still fit, but a theme that wants different depth strength would need those alphas moved into tokens. Both files belong to another developer, so this is left as a [proposed change](#proposed-change-depth-strength-tokens) for them.
- `/styleguide` itself still previews Classic only (its theme lines belong to the lead UI/UX developer); `/styleguide/themes` shows every theme instead.

## Proposed change: depth strength tokens

For the owner of `ui/depth.dart` and `shared/widgets/tactile.dart`. Today these alphas are picked by brightness:

| File | Use | Light | Dark |
| --- | --- | --- | --- |
| depth.dart `InsetBox` | inner shade / inner light | 0.20 / 0.90 | 0.55 / 0.06 |
| depth.dart `DepthCard` | outer shade / highlight | 0.22 / 0.85 | 0.65 / 0.03 |
| depth.dart `DepthCard` selected | shade / highlight | 0.18 / 0.80 | 0.55 / 0.05 |
| depth.dart `DepthCard` face tint | shade over the plate | 0.04 | 0.00 |
| depth.dart `IconWell` | highlight, tone fill | 0.80, 0.14 | 0.04, 0.16 |
| depth.dart `DepthGroove` | shade / highlight | 0.14 / 0.90 | 0.60 / 0.05 |
| tactile.dart secondary edge, top light, sheen, gloss | edge, light, sheen, gloss | 0.22, 0.90, 0.45, 0.55 | 0.12, 0.10, 0.05, 0.06 |
| tactile.dart `bevelColors` | light / shade | white / `#8E9DB5`@0.45 | white@0.06 / black@0.35 |

Proposal: a `DepthStrength` value with one field per row (`wellShade`, `wellLight`, `cardShade`, `cardLight`, …), `DepthStrength.light` and `.dark` holding exactly the numbers above, and a `strength` field on `DepthTheme` (and `TactileTokens`) defaulting to the one for its brightness. Every widget reads `d.strength.cardShade` instead of `dark ? 0.65 : 0.22`. Classic does not change by a pixel; a theme bundle can then pass its own values. `test/skin_tokens_test.dart` would check that Classic's strengths equal today's.

## References

- Wonderboard: `docs/themes/backrooms.md`, `docs/themes/denia.md`; notes `14-crop-backrooms-theme-content-zoom-popup-dismissa.md`, `20-backrooms-theme-switch-animation.md`, `31-denia-theme-and-bug-fix-pass-4.md`, `32-denia-stickers-switch-and-bug-fix-pass-5.md`, `33-denia-stickers-from-the-users-pictures.md`, `50-tablet-drawer-performance-and-theme-polish.md`.
- The Backrooms: [Wikipedia](https://en.wikipedia.org/wiki/The_Backrooms) (a 2019 4chan /x/ thread built on an earlier photo of a carpeted office), [Backrooms Wiki, Level 0](https://backrooms.fandom.com/wiki/Level_0) (yellowed wallpaper, the constant hum of the lights).
- Neumorphism: [Neumorphism (Wikipedia)](https://en.wikipedia.org/wiki/Neumorphism); [Axess Lab, "Neumorphism – the accessible and inclusive way"](https://axesslab.com/neumorphism/); [UX Collective, "The challenge of digital accessibility in user interfaces: the example of Neumorphism"](https://uxdesign.cc/the-challenge-of-digital-accessibility-in-user-interfaces-the-example-of-neumorphism-ac9815ae3b86); [LogRocket, "Neumorphism UI design"](https://blog.logrocket.com/ux-design/neumorphism-ui-design). Takeaways used here: one light source (top left), mirrored shadow offsets, lighter-not-white highlights in dark themes, and contrast carried by text, rims and focus rings rather than by shadow alone.
- WCAG 2.2: [1.4.3 Contrast (Minimum)](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum), [1.4.11 Non-text Contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast), [2.3.3 Animation from Interactions](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions).
- Flutter: [ThemeExtension](https://api.flutter.dev/flutter/material/ThemeExtension-class.html), [CustomPainter](https://api.flutter.dev/flutter/rendering/CustomPainter-class.html); [audioplayers](https://pub.dev/packages/audioplayers) (raw bytes play where the platform supports them); [flutter_svg](https://pub.dev/packages/flutter_svg).
