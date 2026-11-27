# Changelog

## Unreleased — AI Coach personality (branch `experimental-themes`)

The lead UI/UX review was waived by the project lead (D50–D53, D55–D58, [docs/COACH_PERSONALITY.md](docs/COACH_PERSONALITY.md)).

### Added

- **Settings > AI Coach:** 17 coach personalities (Default to Cute & Shy, plus Custom), picked with one tap, with Undo, a description and sample replies to a technique and a setback question.
- **Coach personality page** (Settings > AI Coach > Customize): ten attribute sliders with bands and resets, response length, explanation level, emoji, humour style, pushback, initiative and emotion, the coach's name and pronouns, what it calls you, reply language, your own instructions and words, and Save/Discard.
- **Profiles:** up to 20 saved personalities to use, edit, rename, duplicate, delete (with Undo), export and import.
- **Describe it, AI drafts it:** a description becomes a draft personality to review before saving; without the AI, the app drafts one from keywords.
- **In the coach:** the chosen personality goes with every question in session chat, the general coach and the practice follow-up (D58); the app bar shows it and switches it, and a change keeps the conversation with a "Coach is now …" line.
- **Backend:** a personality block built from the validated settings, after the coach's rules and data; the player's own words in a delimited, style-only block; serious mode for pain, injury and distress; `POST /coach/personality/generate`; `coach_personality` on `/health`; `personality_label` on answers.

- **Crisis support line:** self-harm or suicide words get a fixed support message first, pointing to local emergency services, a crisis line and people the player trusts. The wording is a placeholder (D57).

### Fixed

- **Distress is never off topic:** a player who says they feel hopeless after a loss gets a calm answer instead of "I can only help with badminton" (D56).

### Not included

- The crisis line names no specific hotline until reviewed, localised resources replace the placeholder.

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
