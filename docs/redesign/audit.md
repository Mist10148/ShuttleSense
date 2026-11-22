# Design audit: current app (before redesign)

**Captured:** 2026-11-22. Commit 93f18b4, Flutter web debug build, demo server (`SHUTTLESENSE_FAKE_PIPELINE=1`), synthetic clip.

**Screenshots:** `docs/media/redesign/before/`, named `NN-screen_SIZE_THEME.png`.
- Sizes: 1280×800, 1440×900, 1920×1080 and phone 390×844.
- Themes: light and dark.

**Feature checklist:** [feature-inventory.md](feature-inventory.md).

## Overall impression
The pastel/glass system is tidy and consistent, and contrast is mostly good. The problem is how the space is used, not the styling:
- Most pages are narrow columns floating in a large empty canvas.
- The one page that needs space, Results, crams everything into a narrow side column.
- Nothing on the analysis screens feels like sport. Results reads like a settings page with a video in it.
- The biggest opportunity is the Results page.

## Findings by screen

### Results (highest priority)
| # | Finding | Evidence | Severity |
|---|---|---|---|
| R1 | The court, coach notes and scoreboard share one scrolling column 300–400 px wide. At 1440×900 only the court card is visible; coach and score are hidden below it, inside that column's own scroll, and are easy to miss. | `results_layout.dart:123-133`; `09-results-singles_1440_*.png` (second card peeks at the bottom) | 🔴 |
| R2 | The court is drawn small and on its side (about 270×100 px at 1440) because it must fit that column. Player dots, the trail and the heatmap are hard to read. | `09-results-*_1440_*`; `courtViewLayout` at `court_minimap.dart:72` | 🔴 |
| R3 | The video sits in a card about three times its width, with large empty bands either side. The stage is not used. | `09-results-singles_1440_light.png` | 🟡 |
| R4 | The status strip (IN PLAY · Speed · Peak · Strokes) is a row of small grey chips. The numbers that matter most, speed and peak, have the least visual weight. Meanwhile the four stat tiles above repeat "Peak speed" at large size. | same | 🟡 |
| R5 | **Bug:** in dark mode the video card overflows by 2.0 px (debug stripe visible). The 1 px dark hairline border (`surfaces.dart:131`) is not subtracted in `_videoCard` (`results_layout.dart:64`). | `09-results-singles_1440_dark.png`; browser console RenderFlex overflow | 🟡 |
| R6 | The timeline is a plain list below the fold. Stroke, player and time are not scannable as a table, and filter chips sit centred far from the rows they filter. | `09-*_1440_*` | 🟡 |
| R7 | The court legend wraps onto two lines ("60–<100 · 100+"), and there is no heatmap legend or scale. | `09-*_1440_light.png` | 🟢 |
| R8 | On phones the four tabs work, but the stats row is hidden (it needs height ≥ 640 and a non-phone width), so phones never see the summary numbers. | `results_screen.dart:72,160`; `09-*_m390_*` | 🟡 |

### Live
| # | Finding | Severity |
|---|---|---|
| L1 | The ready state has a long, dense setup card (match, first server, change ends, lines, stroke model with paragraphs) beside the camera. Every option is visible at once, and the stroke-model explanation is body text in the main flow. | 🟡 |
| L2 | "Before you start" tips push setup below the fold on phones. On phones the camera, two buttons, tips and setup are all stacked in one long scroll. | 🟡 |

### Upload / Watch / Mode
| # | Finding | Severity |
|---|---|---|
| U1 | Upload is a 720 px column at 1440. Step 2 (options: toggles, grouped overlay chips, advanced) runs well below the fold while the right half of the screen is empty. | 🟡 |
| U2 | Watch is a single drop zone at the top of an empty page. The 1440 canvas is about 85% empty. | 🟡 |
| U3 | "Change mode" is styled differently on Watch (plain text) than on Upload and Live (icon button). See the inventory. | 🟢 |
| U4 | Mode cards: the "You need…" line is the same size and colour as the description. | 🟢 |

### Home
| # | Finding | Severity |
|---|---|---|
| H1 | The three action cards are equal pastel blocks, so no primary action stands out. The rest of Home (recent and stroke mix) takes the left two-thirds, leaving an empty right third at 1440 and 1920. | 🟡 |
| H2 | Stroke mix shows "1 · 33%" bars for one analysis only. It is low in information. | 🟢 |

### History / Settings / Coach / Connect / 404
| # | Finding | Severity |
|---|---|---|
| X1 | History is a 720 px list of cards, each row 2 lines with the job ID shown. On desktop a table (file, mode, court, date, status, actions) would scan better. | 🟡 |
| X2 | Settings is one 720 px column of cards; Privacy and About sit below the fold at 1440×900. | 🟢 |
| X3 | Coach (`/coach`) and 404 render **without the shell**: no rail or top bar, and the title sits flush in the corner. This is inconsistent with every other page. | 🟡 |
| X4 | The "chat off" empty states are long paragraphs of small grey text, centred. | 🟢 |
| X5 | Connect is fine. The help (?) icon floats beside the title rather than with the form. | 🟢 |

## Cross-cutting
- **Width:** `PageScaffold` caps most pages at 720 px. At 1920 the content uses about 37% of the panel. There is no layout designed for 1440 px and wider.
- **Hierarchy:** page titles are 48 px light, the largest element on every page, larger than the data. On analysis screens the data should lead.
- **Colour:**
  - Pastels are used decoratively (mode cards) and also for data (chart series), which weakens their meaning.
  - Shuttle-speed colours are hard-coded (`shuttle_speed.dart:3`).
- **Small text:** captions in the 11–12 px label range carry real information (status strip, legend, stroke details). At 1440 they are hard to read.
- **Dark theme:** consistent, but flat. Cards and background differ only slightly, so the panels blur together (`09-*_dark`, `12-*_dark`).
- **What works and should be kept:**
  - The design tokens and the `/styleguide`.
  - Contrast-checked text colours.
  - The glass shell and rail.
  - The status pills.
  - The phone bottom bar.
  - The step indicator on Upload.
  - Empty states that explain *why*.

## Environment notes (not frontend issues)
- **Black results video.** The demo server re-encodes the output video with OpenCV's fallback codec (MPEG-4 Part 2, FourCC `FMP4`) because ffmpeg is not installed, and browsers cannot play it. `docs/SETUP.md` lists ffmpeg as required for H.264 export. Installing it (`winget install Gyan.FFmpeg`) would show real frames in Results.
- **Processing screenshot.** `08-processing` shows Results, because finished jobs go straight to results.

## Priority for the redesign
1. **Results:** split it into a persistent video stage with a HUD strip, plus full-width workspaces (Court, Timeline, Stats, Score, Coach). Fix R5.
2. **Court and heatmap:** a large, upright, legible court, with a legend and modes (plan Phase 5).
3. **Live:** a calm ready state with progressive disclosure, and a HUD running view.
4. **Wide layouts** for Upload, Watch, Home and History. Put Coach and 404 inside the shell.
5. **Type and colour roles:** data leads, titles shrink on analysis screens, and the pastels are reserved for one role.
