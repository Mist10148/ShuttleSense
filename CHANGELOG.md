# Changelog

## Unreleased — AI Coach personality, plan only (branch `experimental-themes`)

Design and documentation only; no app or backend behaviour changes yet (D50–D53, [docs/COACH_PERSONALITY.md](docs/COACH_PERSONALITY.md), [Phase 14](docs/phases/phase-14-coach-personality.md)).

### Added

- **Personality design:** 17 coach presets (Default to Cute & Shy, plus Custom), each with a description, icon, attribute vector, prompt fragment, serious-mode note and sample replies.
- **Customization plan:** ten attribute sliders with intensity bands, communication preferences (name, pronouns, nickname, length, explanation level, emoji, humour, language, vocabulary and more), custom instructions, saved profiles, import and export, and an AI-assisted generator.
- **Architecture:** a layered prompt builder that keeps the coach's rules first, treats player-written text as untrusted, and switches every personality to a serious register for pain, injury and distress.
- **Specs:** JSON Schema for profiles and export files, UI wireframes, security and privacy analysis, a test and evaluation plan, and a phased roadmap.

## Unreleased — experimental themes (branch `experimental-themes`)

Needs a review from the lead UI/UX developer before merge (D49, [docs/THEMES.md](docs/THEMES.md)).

### Added

- **Settings > Theme:** Classic, Backrooms, Denia (Light) and Denia (Dark). Each theme is a full set of tactile tokens, so raised plates, wells and keys keep their look in the new tones. Line-call and player colours stay as they are.
- **Backrooms:** yellowed office wallpaper with plaster grain under a fluorescent ceiling light. Switching to it goes black, shows the Backrooms logo, then reveals the theme with a click and a fading hum.
- **Denia (Light) and (Dark):** a bubble-and-star pattern, a stage light, lace, and Denia stickers at Faint, Normal or Strong. Switching plays an iris of colour, rising bubbles that pop, sparkles and a "Stagecraft" or "Breakdown" card, with synthesized chimes, a whoosh and bubble bloops.
- **Controls:** the switch animation and its sound can each be turned off. Reduced motion skips the animation, and high contrast drops the decoration.
- **Light and Dark per theme:** the navigation rail's sun/moon button and Settings > Appearance move Denia between its light and dark sides; Backrooms, which is light only, says so (D54).
- **Theme gallery:** `/styleguide/themes`, linked from the Theme card, shows the main components in every theme at once.
- **Denia props:** the drawn stickers get their white die-cut rim and soft shadow.
- **Sliders:** themed with ink on a sunken track, at 3:1 against cards in every theme.

### Fixed

- **First switch sound on the web:** the first tap unlocks browser audio, so the first theme switch is no longer silent.

## Unreleased — automatic scoring

### Fixed

- **Landings are found on HD video:** the rest rule tolerates tracker jitter (radius scaled to the frame height) and a missed detection or two, so points are awarded automatically instead of staying 0–0.
- **No false points:** a static false detection, a shuttle held in a hand, a rest far off court, a landing on the net line, or an OUT call that disagrees with the last detected hitter no longer award a point; the rally waits for the user (D45).
- **Doubles lines:** line calls always use the match's singles or doubles court.
- **Shuttle lost as it lands:** when the tracker misses the shuttle as it falls and finds it again lying where it fell, that is the landing, so the rally scores in uploads, Live and Watch (D46).

## Unreleased — app redesign

The Flutter app moves to a light, card-based look with pastel accents. It ships in six stacked pull requests.

### Added

- **Design system (#150):** colour, spacing and radius tokens; the Outfit typeface; shared components (cards, icon chips, pills, skeletons); a styleguide page at `#/styleguide`.
- **App shell (#151):** a glass navigation rail and bar, and one page header style on every page.
- **Home and starting an analysis (#152):** Home page, mode cards, an upload drop zone, the calibration panel and the processing card.
- **Results (#153):** a results page with a stats row, pill tabs and the coach chat in the new layout.
- **Live and Watch & Analyze (#155):** both modes laid out in cards.
- **History, Connect and 404 (stage 6):** History rows as cards with a status chip and skeleton rows while loading; the Connect form in a card; a "Page not found" page with a way back to Home for unknown links.

### Fixed

- The coach chat link no longer bounces back to Results (#154).

### Not included

These were in the design reference but are left out because the backend has no data for them yet: Players, Performance trends, PDF export and History thumbnails.
