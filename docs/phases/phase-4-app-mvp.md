# Phase 4 — App MVP

[← Phase 3](phase-3-classifier.md) · [Phase overview](../PHASES.md) · Next: [Phase 5 — P2 analysis →](phase-5-analysis.md)

| | |
| --- | --- |
| **Dates** | Thu Nov 5 – Fri Nov 13, 2026 |
| **Goal** | The full P1 flow (connect → upload → progress → results with video and timeline) works and looks right on a phone, a tablet, a Windows laptop and in Chrome |
| **Owners** | M6 (app screens), M4 (app tests, accessibility, icon), M1 (API support and reviews) |
| **Entry criteria** | T1.2 API frozen; T1.8 connectivity on all platforms; T1.10 fake pipeline for non-empty results |
| **Exit gate** | Manual run of the P1 flow passes on Android phone, Android tablet (or emulator), Windows and Chrome; widget tests cover each screen at 360, 800 and 1280 dp |
| **Milestone** | `Phase 4 — App MVP` (due Nov 13) |

Built against the stub/fake backend first (`SHUTTLESENSE_FAKE_PIPELINE=1`), then switched to the real pipeline as Phases 2–3 land.

## Tasks

| ID | Task | Owner | Est. | Depends | Status | Issue |
| --- | --- | --- | --- | --- | --- | --- |
| [T4.1](#t41) | Connect screen polish and validation | M6 | 4 h | T1.2 | ⬜ | [#49](https://github.com/Mist10148/ShuttleSense/issues/49) |
| [T4.2](#t42) | Upload: pick, inspect, upload with progress and cancel | M6 | 6 h | T4.1 | ⬜ | [#50](https://github.com/Mist10148/ShuttleSense/issues/50) |
| [T4.3](#t43) | Overlay options and job start | M6 | 3 h | T4.2 | ⬜ | [#51](https://github.com/Mist10148/ShuttleSense/issues/51) |
| [T4.4](#t44) | Processing screen: stages, queue, errors, cancel | M6 | 4 h | T4.3 | ⬜ | [#52](https://github.com/Mist10148/ShuttleSense/issues/52) |
| [T4.5](#t45) | Results layout for compact / medium / expanded | M6 | 6 h | T4.4 | ⬜ | [#53](https://github.com/Mist10148/ShuttleSense/issues/53) |
| [T4.6](#t46) | Video player with auth, controls, fullscreen | M6 | 6 h | T4.5, T2.7 | ⬜ | [#54](https://github.com/Mist10148/ShuttleSense/issues/54) |
| [T4.7](#t47) | Stroke timeline synced with playback | M6 | 5 h | T4.6, T3.10 | ⬜ | [#55](https://github.com/Mist10148/ShuttleSense/issues/55) |
| [T4.8](#t48) | History screen with delete | M6 | 3 h | T4.4 | ✅ | [#56](https://github.com/Mist10148/ShuttleSense/issues/56) |
| [T4.9](#t49) | Error, empty, loading and offline states; theming | M6 | 4 h | T4.1–T4.8 | ⬜ | [#57](https://github.com/Mist10148/ShuttleSense/issues/57) |
| [T4.10](#t410) | Platform configuration for release builds | M6 | 3 h | — | ✅ | [#58](https://github.com/Mist10148/ShuttleSense/issues/58) |
| [T4.11](#t411) | Accessibility pass | M4 | 3 h | T4.9 | ⬜ | [#59](https://github.com/Mist10148/ShuttleSense/issues/59) |
| [T4.12](#t412) | Widget tests with a fake API | M4 | 6 h | T4.4 | ✅ | [#60](https://github.com/Mist10148/ShuttleSense/issues/60) |
| [T4.13](#t413) | App icon and splash screen | M4 | 2 h | — | ⬜ | [#61](https://github.com/Mist10148/ShuttleSense/issues/61) |

---

<a id="t41"></a>
### T4.1 · Connect screen polish and validation

**Owner:** M6 · **Estimate:** 4 h · **Priority:** C · **Area:** app · **Refs:** C1, FR-C1 · **Depends on:** T1.2 · **Blocks:** T4.2

**Inputs.** Existing `app/lib/features/connect/connect_screen.dart`, `ServerConfig.normalizeUrl`, `ApiClient.health()`.

**Steps**
- [x] Validate the URL (`Uri.tryParse`, host present) before calling the server; show field-level errors.
- [x] After a successful health check, show the server's device (CPU/CUDA), version and schema version for 1 s before navigating, and warn if `schema_version` ≠ the app's expected `"1.0"` (constant in `data/models/clip_record.dart`).
- [x] Remember the last 3 servers (`shared_preferences` list) and show them as chips for one-tap reconnect.
- [x] Help link "How do I find my laptop's address?" opening a bottom sheet with the steps from SETUP.md §8.
- [x] Web build: if the page is `https://` and the URL is `http://`, show "Browsers block http servers from https pages; use the tunnel URL".

**Tests.** `test/connect_upload_test.dart`: invalid URL shows error; success navigates home (fake `ApiClient` via provider override, see T4.12); schema mismatch warning.

**Acceptance criteria.** Works on all four platforms; every failure case has a human-readable message.

---

<a id="t42"></a>
### T4.2 · Upload: pick, inspect, upload with progress and cancel

**Owner:** M6 · **Estimate:** 6 h · **Priority:** C · **Area:** app · **Refs:** C2, FR-C2, F1 · **Depends on:** T4.1 · **Blocks:** T4.3, T5.1

**Inputs.** `features/upload/upload_screen.dart`; `FilePicker.pickFiles` (file_picker 13 API), `ApiClient.uploadVideo`.

**Steps**
- [x] On Android/iOS also offer "Choose from gallery" (`FileType.video`), on desktop/web "Choose file".
- [x] Before upload show name, size and (after upload) duration/resolution/fps from `VideoInfo`; warn if > 5 minutes or > 1 GB before sending. (Duration is read on the device with a throwaway media_kit player; skipped on web, where the server still refuses long clips.)
- [x] Upload progress bar with MB sent / total and cancel (`CancelToken`); keep the screen awake during upload on mobile (optional: `wakelock_plus`, add to TECH_STACK if used).
- [x] On failure keep the picked file so the user can retry without re-picking.
- [x] Move upload state into `features/upload/upload_controller.dart` (Riverpod `Notifier`) so the widget only renders state.

**Tests.** `test/connect_upload_test.dart`: progress updates from a fake upload stream; cancel resets state; error message shown.

**Acceptance criteria.** 1-minute 1080p clip uploads from Android phone, Windows and Chrome with live progress; cancel works.

---

<a id="t43"></a>
### T4.3 · Overlay options and job start

**Owner:** M6 · **Estimate:** 3 h · **Priority:** C · **Area:** app · **Refs:** C2 · **Depends on:** T4.2 · **Blocks:** T4.4

**Steps**
- [x] Disable overlay chips whose stage is not available (`Health.stages`, from T1.2) with a tooltip "Not installed on this server".
- [x] Persist the last overlay choice in `shared_preferences`.
- [x] Court-dependent overlays (`court`, `minimap`, `speed`, `score`) are greyed out when "Calibrate court" is off.
- [x] "Upload and analyze" calls `createJob` and navigates to `Routes.job(id)`.

**Tests.** `test/connect_upload_test.dart` (court overlays disabled without calibration) and `test/calibration_test.dart` (skip sends no court overlays).

**Acceptance criteria.** The job request contains exactly the chosen overlays (verify in backend log).

---

<a id="t44"></a>
### T4.4 · Processing screen: stages, queue, errors, cancel

**Owner:** M6 · **Estimate:** 4 h · **Priority:** C · **Area:** app · **Refs:** C2, FR-C2 · **Depends on:** T4.3 · **Blocks:** T4.5, T4.8, T4.12

**Inputs.** `features/processing/processing_screen.dart`, `jobProvider` (polling stream).

**Steps**
- [x] Back-off on network errors in `jobProvider`: retry after 2, 4, 8 … up to 30 s before surfacing the error (API.md polling guidance).
- [x] Show elapsed time and an ETA from progress rate.
- [x] Cancel asks for confirmation, then `DELETE /jobs/{id}`.
- [x] On `failed`, show the error and a "Try again" button that re-submits the same options.
- [ ] Optional: local notification when done if the app is backgrounded (mobile) — only if time allows.

**Tests.** `test/processing_test.dart`: renders stage list; navigates to results on `done`; shows retry on `failed`.

**Acceptance criteria.** Progress updates at least every 2 s; navigation to results is automatic.

---

<a id="t45"></a>
### T4.5 · Results layout for compact / medium / expanded

**Owner:** M6 · **Estimate:** 6 h · **Priority:** C · **Area:** app · **Refs:** C3, FR-C3 · **Depends on:** T4.4 · **Blocks:** T4.6, T5.5, T6.5

**Inputs.** `features/results/widgets/results_layout.dart` (`ResultsLayout`), golden record from T1.10.

**Steps**
- [x] Phone landscape: when height < 500 dp, show video fullscreen-style with a slide-up panel for the timeline.
- [x] Expanded: make the right panel width responsive (min 300, max 400 dp).
- [x] Add a summary card (total hits, peak speed, stroke distribution chart with `fl_chart`) to the side panel / Score tab.
- [x] Keep the video aspect ratio from `record.width/height`; letterbox, never stretch.

**Tests.** Extend `test/responsive_test.dart`: phone landscape (780×360), tablet landscape (1100×800); assert no overflow and the right zones exist.

**Acceptance criteria.** No overflow from 360 to 1920 dp, portrait and landscape.

---

<a id="t46"></a>
### T4.6 · Video player with auth, controls, fullscreen

**Owner:** M6 · **Estimate:** 6 h · **Priority:** C · **Area:** app · **Refs:** C3, F7 · **Depends on:** T4.5, T2.7 · **Blocks:** T4.7, T5.5

**Inputs.** `features/results/widgets/video_panel.dart` (`openPlayer`, `VideoPanel`), `ApiClient.videoUrl` (adds `?token=` for web).

**Steps**
- [x] Use media_kit's `MaterialVideoControls` (mobile) / `MaterialDesktopVideoControls` (desktop/web) and fullscreen.
- [x] Playback speed control (0.25×, 0.5×, 1×) for reviewing strokes.
- [x] Frame step buttons (±1 frame = 1/fps s).
- [x] When `outputs.video` is false, keep the "not available" panel but still allow the timeline/minimap.
- [ ] Verify auth: header on native, `?token=` on web.

**Tests.** Player is native; cover with manual checks plus a widget test of the "not available" state.

**Acceptance criteria.** Plays, seeks and goes fullscreen on Android, Windows and Chrome (and iOS if available) with a token-protected server.

---

<a id="t47"></a>
### T4.7 · Stroke timeline synced with playback

**Owner:** M6 · **Estimate:** 5 h · **Priority:** C · **Area:** app · **Refs:** C3, FR-C3 · **Depends on:** T4.6, T3.10 · **Blocks:** T5.9, T7.4

**Inputs.** `features/results/widgets/stroke_timeline.dart`, `ClipRecord.hitAt`, `Hit.position`.

**Steps**
- [x] Auto-scroll the list to keep the current hit visible (`Scrollable.ensureVisible` or `ScrollController.animateTo`).
- [x] Seek to 0.5 s before the hit so the stroke is seen in context.
- [x] Filter chips by player (Near/Far) and by stroke class.
- [x] Tap-and-hold a row → detail bottom sheet (all class probabilities, speed, tips).
- [x] Mark low-confidence (< 0.5) labels with a "?" badge (NFR Transparency).

**Tests.** `test/timeline_test.dart`: tapping a row calls `onSeek` with the right position; filters reduce rows; low-confidence badge appears.

**Acceptance criteria.** Highlight follows playback; tapping seeks on all platforms.

---

<a id="t48"></a>
### T4.8 · History screen with delete

**Owner:** M6 · **Estimate:** 3 h · **Priority:** C · **Area:** app · **Refs:** C2, NFR Privacy · **Depends on:** T4.4 · **Blocks:** —

**Steps**
- [x] Show the original video filename (add `filename` to the Job response or fetch `GET /videos/{id}`; coordinate with M1 if the API changes — contract change policy).
- [x] Swipe-to-delete on mobile, delete icon on desktop, both with confirmation.
- [x] "Delete video too" option (`DELETE /videos/{id}`).
- [x] Pull-to-refresh and empty state (exists).

**Tests.** `test/history_test.dart`: list renders; delete calls the API and refreshes.

**Acceptance criteria.** Deleted jobs disappear from the server (`GET /jobs/{id}` → 404).

**Verified (Nov 12).** `backend/tests/test_api.py::test_full_round_trip` deletes a job and gets
404 for it, then deletes its video and gets 404 for that too; `test/history_test.dart` covers
the app side. Issue #56 can be closed.

---

<a id="t49"></a>
### T4.9 · Error, empty, loading and offline states; theming

**Owner:** M6 · **Estimate:** 4 h · **Priority:** C · **Area:** app · **Refs:** NFR Usability · **Depends on:** T4.1–T4.8 · **Blocks:** T4.11

**Steps**
- [x] Global offline banner when the last API call failed with a connection error (implemented as `OfflineBanner` in `shared/widgets/offline_banner.dart`, driven by `healthProvider`, which re-checks the server every 30 s, or every 10 s while unreachable).
- [x] Every screen has loading, empty and error states using `MessageView`.
- [x] Settings: theme mode (system/light/dark) persisted; wire into `MaterialApp.themeMode`.
- [ ] Review every screen in light and dark mode on phone and laptop.

**Acceptance criteria.** Screenshots of each screen in both themes attached to the PR.

---

<a id="t410"></a>
### T4.10 · Platform configuration for release builds

**Owner:** M6 · **Estimate:** 3 h · **Priority:** C · **Area:** app · **Refs:** NFR Platforms · **Depends on:** — · **Blocks:** T7.6

**Steps**
- [x] Android: `applicationId com.shuttlesense.app`, version from `pubspec.yaml`; release signing config reading `android/key.properties` (gitignored); keep cleartext enabled (LAN use) and document why.
- [x] Android: add `READ_MEDIA_VIDEO` (API 33+) if the gallery picker needs it.
- [x] iOS: bundle id, display name, `NSPhotoLibraryUsageDescription` (exists), minimum iOS version.
- [x] Windows: app name, version info in `Runner.rc`, window min size 400×600 in `main.cpp`.
- [x] Web: `manifest.json` name, theme colour `#2E7D4F`, description.

**Acceptance criteria.** `flutter build apk --release`, `flutter build windows --release`, `flutter build web --release` succeed locally.

**Verified (Nov 12).** All three release builds succeed on the team laptop (the APK is
debug-signed until the release keystore exists, T7.6). Issue #58 can be closed.

---

<a id="t411"></a>
### T4.11 · Accessibility pass

**Owner:** M4 · **Estimate:** 3 h · **Priority:** C · **Area:** app · **Refs:** NFR Usability · **Depends on:** T4.9 · **Blocks:** —

**Steps**
- [ ] Text scale 200% on phone: no clipped text or overflow on any screen.
- [x] Semantics labels for icon-only buttons and the minimap ("Near player at 2.6 m, 1.9 m").
- [x] Contrast check of player colours on the court background in both themes (≥ 3:1 for graphics).
- [x] Keyboard: Tab order and Enter/Space on desktop/web; Space toggles play/pause on results.

**Tests.** `test/accessibility_test.dart` using `meetsGuideline(textContrastGuideline)` and `androidTapTargetGuideline` on main screens.

**Acceptance criteria.** Guideline tests pass; 200% text scale reviewed on a phone.

---

<a id="t412"></a>
### T4.12 · Widget tests with a fake API

**Owner:** M4 · **Estimate:** 6 h · **Priority:** C · **Area:** app · **Refs:** ARCHITECTURE §6 · **Depends on:** T4.4 · **Blocks:** T4.1–T4.8 tests

**Steps**
- [x] `test/fakes/fake_api_client.dart`: implements `ApiClient`'s public methods with in-memory jobs/videos and scripted progress.
- [x] Override `apiClientProvider` in tests; helper `pumpScreen(tester, widget, size: phone)`.
- [x] Golden record fixture (T1.10) for results tests.
- [x] Run every screen at 360×780, 800×1100, 1280×800 and assert `tester.takeException()` is null.

**Acceptance criteria.** ≥ 1 test per screen; CI `flutter test` green.

---

<a id="t413"></a>
### T4.13 · App icon and splash screen

**Owner:** M4 · **Estimate:** 2 h · **Priority:** C · **Area:** app · **Refs:** — · **Depends on:** — · **Blocks:** T7.6

**Steps**
- [x] Design a shuttlecock mark in the app palette. Regenerate platform assets with
  `python app/tool/generate_brand_assets.py` from the repository root (requires Pillow).
- [x] Add Android and iOS launch screens, Windows launcher artwork, and a web loading screen.
- [x] Replace the default web favicon and installed web app icons.
- [ ] M4 reviews the artwork and verifies the launcher icon and startup on the target devices.

**Acceptance criteria.** Custom icon on Android, Windows taskbar and browser tab.

---

## Phase gate checklist (Nov 13)

1. Live: connect from a phone, upload, watch progress, open results, tap a timeline row.
2. Same on Windows and Chrome; show tablet layout (device or emulator).
3. Run `flutter test` and show the count.
4. Show light/dark screenshots.
