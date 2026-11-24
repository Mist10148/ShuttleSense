# Changelog

## Unreleased — automatic scoring

### Fixed

- **Landings are found on HD video:** the rest rule tolerates tracker jitter (radius scaled to the frame height) and a missed detection or two, so points are awarded automatically instead of staying 0–0.
- **No false points:** a static false detection, a shuttle held in a hand, a rest far off court, a landing on the net line, or an OUT call that disagrees with the last detected hitter no longer award a point; the rally waits for the user (D45).
- **Doubles lines:** line calls always use the match's singles or doubles court.

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
