# Themes

> **Experimental.** This work lives on the `experimental-themes` branch. It edits a few lines of the theme builder that Delariman and Limpin wrote, so it needs a review from the lead UI/UX developer (Limpin) before anything here is merged (CONTRIBUTING.md). Decision: D49.

ShuttleSense has one look, the tactile (neumorphic) design, in light and dark. This page plans and records three more themes that sit on top of it:

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
4. **Decoration never takes input** and never sits under text without a surface between them. Wallpaper, lighting, grain and stickers are painted behind pages (in `AppBackground`), or over them only as faint light, with `IgnorePointer`.
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
        ▼                                 ▼
 SkinFxHost (switch animation + sound)   AppBackground ─► SkinBackdrop (wallpaper, pattern,
                                                           stickers, light, grain)
```

- `app/lib/core/theme/app_skin.dart`: the `AppSkin` enum, the saved choice and the effect settings (motion, sound, stickers, sticker strength).
- `app/lib/core/theme/skins/`: one const `SkinBundle` per theme, `SkinDecor` (the theme extension that tells decoration what to paint) and `skinTheme()`.
- `app/lib/shared/widgets/skin/`: the painters (wallpaper, pattern, lighting, grain, lace, stickers).
- `app/lib/features/skins/fx/`: the switch animations and their timing plans.
- `app/lib/core/audio/`: the Denia switch synthesizer and the player.
- Settings has a **Theme** card under Appearance. Classic still follows the Light/Dark/System choice; the other themes carry their own brightness.

Only these lines owned by teammates change: `AppTheme._build` gains optional `tactile`, `analysis`, `depth` and `decor` parameters, and the three lines that chose them by brightness now fall back to that choice (`app_theme.dart`). One line is added to `AppBackground` (surfaces.dart) and two to `SettingsScreen`. Everything else is new files.

## Backrooms

Reference: Wonderboard `src/style.css:4-8`, `src/canvas/cropAndZoom.css:20-58`, `src/fx/backroomsSwitch.ts`, `src/fx/backroomsPlan.ts`, `docs/themes/backrooms.md`, notes 14 and 20.

**Palette** (Wonderboard tokens, then the tactile tones derived from them):

| Role | Value | Notes |
| --- | --- | --- |
| page / canvas | `#B6B461` | the wallpaper base |
| card (raised top) | `#D4D291` | Wonderboard `--card` |
| border / dot | `#8C8A46` | |
| text | `#24230D` | |
| muted text | `#403E14` | |
| accent | `#5A5712` | primary keys, focus |
| line colour | `#4A4720` | |

The neumorphic highlight is a warm, paper-pale yellow and the shade is a dark olive-brown, so plates read as moulded from the same damp plaster as the walls.

**Wallpaper.** An SVG tile, 360×542 drawn at 270×406.5 (75%): base `#B6B461`; two vertical stripes 54 wide at x=63 and x=243 in `#A59F4A`; in each stripe, 10×45 dashes at x=85 and x=265, alternating `#98923F` / `#B3AF5B`, every 180.67 (y = −15.67, 29.33, 165, 210, 345.67, 390.67, …); chevron hexagons in `#9A9340`: `180,248 235,310 235,395 180,336 125,395 125,310` and `180,369 235,432 235,463 180,402 125,463 125,432` in the middle column, the same shapes half a tile up and down at x=0 and x=360.

**Ceiling light.** Fixed to the window over the wallpaper:
`linear-gradient(to bottom, transparent 32%, rgba(30,28,4,.18) 66%, rgba(30,28,4,.46) 100%)`,
`radial-gradient(ellipse 62% 48% at 50% -6%, rgba(255,252,206,.46), rgba(255,252,206,.18) 48%, transparent 78%)`,
`radial-gradient(ellipse 130% 105% at 50% 22%, transparent 52%, rgba(38,36,6,.30) 100%)`.

**Plaster grain.** Two layers of fractal noise on the navigation surfaces: a pale warm speck layer (`feTurbulence` 0.45, 2 octaves, colour ≈ `rgb(255,250,199)` at up to 50%) and a dark olive layer (0.7, 3 octaves, ≈ `rgb(51,48,8)` at up to 55%). In Flutter it is a seeded, deterministic speck tile recorded once.

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

**Pattern**: a 240 px tile of soap bubbles and stars (exact positions in `denia_pattern_painter.dart`, taken from decor.ts).

**Lace**: a row of scallops (2.6 px dots every 11 px, 5 px tall) along the lower edge of top bars and section headers, in the border colour.

**Stickers**: the 16 Denia pictures and the 5 drawn props from Wonderboard, scattered on a hashed grid (cells of 340, 70% filled, 104–168 tall, tilted up to ±0.24 rad, at least 190 apart), at opacity `.35 / .65 / .95` for Faint / Normal / Strong, ×0.85 in Dark. About one cell in 28 shows a short line in a pill instead. Light and Dark use different sticker sets (`artFor`).

**Switch animation**:

| Switch | Bubbles | Theme changes (ms) | Pops (ms) | Ends (ms) |
| --- | --- | --- | --- | --- |
| into Denia | 34 | 620 | 820–1500 | 1800 |
| Light ↔ Dark | 16 | 260 | 380–820 | 1100 |
| leaving Denia | 14 | 160 | 300–680 | 860 |

A colour iris grows from where the user tapped and covers the screen when the theme changes. Iridescent bubbles rise and pop into a ring and droplets. Four-point sparkles twinkle. A card bounces in with "Denia · Stagecraft" or "Denia · Breakdown".

**Sound** (no files, synthesized like Wonderboard's Web Audio score): a whoosh of band-passed noise (350→3200 Hz rising for Light, 2600→500 Hz falling for Dark), a music-box arpeggio around the moment the theme changes (Light rises through E major 659.25–1661.22 Hz, Dark falls through G minor 1174.66–392 Hz; partials ×1, ×2.01, ×3.98), and bubble bloops (a sine chirping up ×2.3 in 55 ms) panned to each pop. Everything is softly compressed and sent through a 1.6 s reverb at 0.32 wet.

## Accessibility and performance

- Reduced motion or the "Switch animation" setting off: no overlay, the theme changes at once, no sound.
- High contrast: every theme collapses to flat borders, as Classic does (`TactileTokens.asFlat`). Decoration is hidden.
- Painters cache their tiles as pictures and sit behind a `RepaintBoundary`; the backdrop does not repaint when pages scroll.

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

## Known limits

- `ui/depth.dart` and `shared/widgets/tactile.dart` hardcode some shadow alphas by brightness. Every theme maps to light or dark, so they still fit, but a theme that wants different depth strength would need those alphas moved into tokens.
- The navigation rail's sun/moon button still flips Classic's light/dark only.
- `/styleguide` previews Classic only.

## References

- Wonderboard: `docs/themes/backrooms.md`, `docs/themes/denia.md`; notes `14-crop-backrooms-theme-content-zoom-popup-dismissa.md`, `20-backrooms-theme-switch-animation.md`, `31-denia-theme-and-bug-fix-pass-4.md`, `32-denia-stickers-switch-and-bug-fix-pass-5.md`, `33-denia-stickers-from-the-users-pictures.md`, `50-tablet-drawer-performance-and-theme-polish.md`.
- The Backrooms: [Wikipedia](https://en.wikipedia.org/wiki/The_Backrooms) (a 2019 4chan /x/ thread built on an earlier photo of a carpeted office), [Backrooms Wiki, Level 0](https://backrooms.fandom.com/wiki/Level_0) (yellowed wallpaper, the constant hum of the lights).
- Neumorphism: [Neumorphism (Wikipedia)](https://en.wikipedia.org/wiki/Neumorphism); [Axess Lab, "Neumorphism – the accessible and inclusive way"](https://axesslab.com/neumorphism/); [UX Collective, "The challenge of digital accessibility in user interfaces: the example of Neumorphism"](https://uxdesign.cc/the-challenge-of-digital-accessibility-in-user-interfaces-the-example-of-neumorphism-ac9815ae3b86); [LogRocket, "Neumorphism UI design"](https://blog.logrocket.com/ux-design/neumorphism-ui-design). Takeaways used here: one light source (top left), mirrored shadow offsets, lighter-not-white highlights in dark themes, and contrast carried by text, rims and focus rings rather than by shadow alone.
- WCAG 2.2: [1.4.3 Contrast (Minimum)](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum), [1.4.11 Non-text Contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast), [2.3.3 Animation from Interactions](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions).
- Flutter: [ThemeExtension](https://api.flutter.dev/flutter/material/ThemeExtension-class.html), [CustomPainter](https://api.flutter.dev/flutter/rendering/CustomPainter-class.html); [audioplayers](https://pub.dev/packages/audioplayers) (raw bytes play where the platform supports them); [flutter_svg](https://pub.dev/packages/flutter_svg).
