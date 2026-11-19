# Changelog

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
