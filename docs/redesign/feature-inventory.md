# ShuttleSense app: feature inventory for the redesign

Source of truth for "no feature lost" checks. Built by reading the code in `app/lib` (state as of commit 93f18b4).
Every mockup and every rebuilt screen must keep each row below: same control, same label (or a deliberate, reviewed rename), same condition.

Conventions

- Paths are relative to `app/lib/`. `file.dart:NN` points at the line that defines the element or its label.
- Labels are quoted exactly from code. `${...}` is an interpolated value. `…` is the real ellipsis character used in the code.
- Window classes (`core/responsive/breakpoints.dart:5-16`): **compact** < 600 dp, **medium** 600-1023, **expanded** >= 1024. Page gutter 16 / 24 / 32 (`breakpoints.dart:31-35`).
- "Health" means the server's `GET /health` answer (`data/models/health.dart`). Feature gates by clip record schema: live >= 1.1, courtside >= 1.5, courtside depth >= 1.6, change of ends >= 1.7 (`health.dart:54-61`). Other flags: `chat_available`, `chat_max_messages`, `stroke_models`, `watch_video`, `watch_background`, `watch_match_type`, per-stage install list.

---

## 0. Routes and global behaviour

`core/router/app_router.dart`

| Route | Screen | In shell? | Notes |
|---|---|---|---|
| `/connect` | ConnectScreen | no | Reachable without a server (`app_router.dart:81`) |
| `/styleguide` | StyleguideScreen | no | Reachable without a server; **not linked from any screen** |
| `/coach` | CoachScreen | no | Pushed from History only (`history_screen.dart:97`) |
| `/dashboard` | HomeScreen | yes, branch 0 "Home" | Initial location (`app_router.dart:53`) |
| `/` | Analyze tab: WatchScreen if mode = watch; LiveScreen if mode = live **and** server supports live; else UploadScreen | yes, branch 1 "Analyze" | `app_router.dart:99-108` |
| `/mode` | ModeScreen | yes, branch 1 | Nested under `/` |
| `/videos/:videoId/calibrate` | CalibrationScreen | yes, branch 1 | |
| `/jobs/:jobId` | ProcessingScreen | yes, branch 1 | |
| `/jobs/:jobId/results` | ResultsScreen | yes, branch 1 | Back goes to Processing (stacked under it) |
| `/jobs/:jobId/results/chat` | ChatScreen | yes, branch 1 | |
| `/history` | HistoryScreen | yes, branch 2 | |
| `/settings` | SettingsScreen | yes, branch 3 | |
| anything else | "Page not found" (errorBuilder) | no | `app_router.dart:55-77` |

Global rules

| Rule | Where |
|---|---|
| Not connected (no saved server) redirects every route except `/connect` and `/styleguide` to `/connect`; re-evaluated when the saved server changes | `app_router.dart:78-84`, `:47-50` |
| Shell branches keep their state (IndexedStack): switching tabs does not dispose Upload/Live/Watch, so an upload or live session continues | `app_router.dart:89`; comment `upload_screen.dart:57-59` |
| Re-selecting the current tab resets that branch to its initial location | `adaptive_shell.dart:35-36` |
| The remembered analysis mode (`ui.mode`, default upload) decides what the Analyze tab shows | `core/config/app_mode.dart:9-21` |
| Theme mode (`ui.themeMode`: system/light/dark, default system) saved on device | `core/theme/theme_mode.dart:7-19` |
| "Notify when done" (`ui.notifyWhenDone`, default on) saved on device | `core/notifications/job_notifier.dart:108-118` |
| System notification when a job ends while the app is in background: title `'Analysis ready'` / `'Analysis failed'`, body `'Your clip has been analysed. Tap to open ShuttleSense.'` / `'Open ShuttleSense to see why.'`; Android channel `'Finished analyses'`. Android, iOS, Windows only | `job_notifier.dart:85-88`, `:53-55`, `:98-105` |
| Notification permission prompt (Android 13+ / iOS) is requested when Processing is opened with notify on | `processing_screen.dart:87`, `job_notifier.dart:63-68` |
| Live session keeps the screen awake while streaming | `live_controller.dart:417-421` |

---

## 1. Shell (rail, top bar, bottom bar, offline banner)

Purpose: frame around the four tab branches. Files: `core/responsive/adaptive_shell.dart`, `shared/widgets/top_bar.dart`, `shared/widgets/offline_banner.dart`, `shared/widgets/status_pill.dart`, `shared/widgets/surfaces.dart` (GlassPanel, AppBackground, IconChip).

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Destinations | nav | `'Home'`, `'Analyze'`, `'History'`, `'Settings'` (adaptive_shell.dart:22-25) | Go to branch; outlined icon, filled when selected | all layouts |
| Bottom navigation bar | nav | same 4 labels (adaptive_shell.dart:52-63) | Material NavigationBar | compact only |
| Icon rail | nav | each button: Tooltip + semantics label = destination label (adaptive_shell.dart:129-134, 169-174) | 80 dp column; selected button filled ink | medium + expanded only |
| Rail brand badge | data display | tooltip `'ShuttleSense'` (adaptive_shell.dart:119-126) | Tennis icon on lavender | medium + expanded |
| Theme toggle (rail) | button | `'Switch to light theme'` / `'Switch to dark theme'` (adaptive_shell.dart:139) | Sets theme to light or dark (never back to system) | medium + expanded only; on compact theme is only in Settings > Appearance |
| Floating glass panel + pastel canvas | layout | - | Margin 24 (medium) / 32 (expanded) | medium + expanded (adaptive_shell.dart:67-73) |
| Brand row | data display | `'ShuttleSense'` (top_bar.dart:37-43) | Badge + app name | compact only |
| Search icon | button | tooltip `'Search analyses'` (top_bar.dart:44-47) | Opens History (does not set a query) | compact only |
| Search field | field | hint `'Search analyses'` (top_bar.dart:51, 70-79) | On submit: writes trimmed text to History's query and opens History | medium + expanded (280 dp wide) |
| Notifications bell | button + menu | tooltip `'Notifications'` or `'Notifications: $running running'` (top_bar.dart:107) | Badge with count of unfinished jobs (top_bar.dart:109-113); toggles menu | all layouts |
| Bell menu: refresh | behaviour | - | Re-fetches the job list every time the menu opens (top_bar.dart:95) | |
| Bell menu: empty item | menu item (disabled) | `'No analyses yet'` (top_bar.dart:97) | | no jobs |
| Bell menu: job items | menu item | `'Analysis finished'`, `'Analysis failed'`, `'Analysis cancelled'`, `'Analysis queued'`, `'Analysis running · NN%'`; `'Live session …'` variants (top_bar.dart:125-134) | Up to 6 newest (top_bar.dart:15). Opens Results if it has results, else Processing (top_bar.dart:101-102). Icon by status (top_bar.dart:118-123) | |
| Server status pill | data display + button | text `'Checking…'` / `'Offline'` / `'Online'`; tooltip `'Server: $label'` (top_bar.dart:148-153) | Health state; tap opens Settings (top_bar.dart:156) | pill on medium + expanded (top_bar.dart:163) |
| Server status dot | data display + button | semantics `'Server $label'`, same tooltip (top_bar.dart:162, 186-194) | Coloured 12 dp dot only | compact only |
| Offline banner | state | `'Server unreachable. Check the Wi-Fi or the tunnel.'` (offline_banner.dart:42) | Pink glass strip above the page, live region | only when health fails with "unreachable" (offline_banner.dart:19-20); not for other errors |
| Offline banner Retry | button | `'Retry'` (offline_banner.dart:46-49) | Re-checks health | with banner |

States: health loading = "Checking…"; any health error = "Offline" pill, but the banner shows only for network-unreachable errors.
Responsive: compact = top bar (brand, search icon, bell, dot) + page + bottom bar; medium/expanded = rail + top bar (search field, bell, pill) inside glass panel.
Navigation out: History (search), Settings (status), Results / Processing (bell items), any branch.

---

## 2. Connect

Purpose: enter backend URL and optional token, check `/health`, save. Files: `features/connect/connect_screen.dart`, `core/config/server_config.dart`. Outside the shell (no rail, no top bar). PageScaffold, max width 480.

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Title | data display | `'Connect to server'` (connect_screen.dart:163) | | |
| Help | button | tooltip `'Help'` (connect_screen.dart:166) | Opens help bottom sheet | |
| App badge + name | data display | `'ShuttleSense'` (connect_screen.dart:170-178) | | |
| Intro | data display | `'Enter the address of the ShuttleSense backend: the laptop on your Wi-Fi (for example http://192.168.1.20:8000) or the Colab tunnel URL.'` (connect_screen.dart:180-182) | | |
| Server address | field | label `'Server address'`, hint `'http://192.168.1.20:8000'` (connect_screen.dart:191-202) | Prefilled with saved URL or default; Enter submits | |
| Recent servers | chips | text = URL, history icon (connect_screen.dart:203-216) | Fills the address field | only if recent list non-empty |
| Mixed content warning | state | `'This page is served over https, so the browser blocks plain http servers. Use the https tunnel address instead.'` (connect_screen.dart:218-224) | Error colour | web only, https page + http address |
| Access token | field (obscured) | label `'Access token (if the server has one)'` (connect_screen.dart:227-236) | Enter submits | |
| Error text | state | the error message, semantics `'Error: $_error'` (connect_screen.dart:237-243) | | after a failed connect |
| Connect | button | `'Connect'` (connect_screen.dart:246-255) | Validates, checks health (+ one authenticated call when a token is given), saves, opens Home | disabled + spinner while busy |

Dialogs / sheets / snackbars

| Kind | Text | Where |
|---|---|---|
| Bottom sheet (drag handle) | `'Finding the server address'` + three paragraphs (uvicorn command, Colab tunnel, `'More in docs/SETUP.md, section 8.'`) | connect_screen.dart:124-153 |
| Dialog | title `'Different data format'`, body "The server sends clip record version X, but this app expects Y…", buttons `'Cancel'` / `'Connect anyway'` | connect_screen.dart:63-82; when schema differs |
| Snackbar | `'Connected: ShuttleSense ${version} on ${DEVICE}'` | connect_screen.dart:109-115 |

Errors shown inline: `'Enter the server address'`, `'That does not look like an address, e.g. http://192.168.1.20:8000'`, `'The port must be 1 to 65535'` (server_config.dart:35-41); `'This server needs an access token'` (connect_screen.dart:104); API errors such as `'Cannot reach server at …'`, `'The server took too long to answer'`, `'The server\'s HTTPS certificate is not trusted'`, `'Wrong or missing access token'` (data/api_client.dart:85-94).
Responsive: single centred column at all sizes. Navigation out: `/dashboard` on success. In: redirect when not connected; Settings "Change server".

---

## 3. Home (dashboard)

Purpose: landing page: start an analysis, recent analyses, stroke mix of the latest finished one. File: `features/home/home_screen.dart` (+ `ModeChoices` from `features/mode/mode_screen.dart`). PageScaffold, no back, max width 1200.

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Title | data display | `'Home'` (home_screen.dart:33) | | |
| "Start an analysis" card | card | `'Start an analysis'` (home_screen.dart:37) | Three mode cards, short descriptions (see Mode §4) | always |
| First-run card | state (empty) | `'No analyses yet'`, `'Your latest analyses and their stroke mix show up here.'` (home_screen.dart:59-63) | | no jobs |
| Upload your first rally | button | `'Upload your first rally'` (home_screen.dart:64-70) | Sets mode = upload, opens Analyze | no jobs |
| Recent analyses | card + list | `'Recent analyses'`, subtitle `'Newest first'` (home_screen.dart:111-112) | 5 newest jobs | jobs exist |
| Recent analyses expand | button | tooltip `'Expand'` (surfaces.dart:157-162) | Opens History (home_screen.dart:113) | |
| Recent row | list row | title = file name, else `'Live session'` / `'Analysis'`; subtitle `'Live · <date>'` / `'Upload · <date>'` (home_screen.dart:134-135) | Trailing: gradient progress labelled `'Processing'` while running (home_screen.dart:136-141), else status pill (`'Done'`, `'Failed'`, `'Cancelled'`, `'Queued'`, `'Processing'`, history_screen.dart:364-370). Tap: Results if results, else Processing (home_screen.dart:142) | |
| Stroke mix | card + chart (bars) | `'Stroke mix'`, subtitle `'Latest analysis · <file>'` (home_screen.dart:165-166) | One labelled bar per stroke class: `'<Stroke>'` + `'<n> · <pct>%'`; semantics `'<Stroke>: n of total strokes'` (home_screen.dart:182-207) | a finished job with results exists |
| Stroke mix expand | button | tooltip `'Expand'` | Opens Results of that job (home_screen.dart:167) | |
| Stroke mix loading | state | 3 skeleton bars (home_screen.dart:168-177) | | record loading |
| Stroke mix empty | state | `'No strokes were named in this analysis.'` (home_screen.dart:179) | | total 0 |
| Camera setup tip | card | `'Camera setup'`, `'Put the phone on a tripod, raised and behind the baseline, with the whole court in frame. Keep it still for the whole rally.'` (home_screen.dart:84-96) | Peach card | no jobs, or no finished job |

Responsive: `CardGrid` (min 340 dp per column, up to 3) - 1 column phone, 2 tablet, 3 laptop (surfaces.dart:297-316). Mode cards grid min width 220.
Job list errors are silent here (treated as empty list). Navigation out: Analyze (`/`), History, Results, Processing.

---

## 4. Mode chooser

Purpose: the one place to pick the analysis mode (Analyze tab landing view). File: `features/mode/mode_screen.dart`. PageScaffold, no back, max width 1080.

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Title | data display | `'How do you want to analyze?'` (mode_screen.dart:20) | | |
| Upload clip card | card button | `'Upload clip'`; detailed: `'Pick a recorded rally. The server processes it and shows full results, line calls and coaching notes.'`, footnote `'You need: a recorded video file (MP4, MOV or AVI)'`; short (Home): `'Analyze a recorded rally.'` (mode_screen.dart:54-65) | Saves mode, opens Analyze | always enabled |
| Go live card | card button | `'Go live'`; detailed `'Point a camera at the court and see the shuttle, score and line calls while you play. The session is saved to History when you stop.'`, footnote `'You need: a camera pointed at the court'`; short `'Use a camera at the court.'` (mode_screen.dart:66-80) | Saves mode, opens Analyze | Disabled with text `'This server is too old for live mode (clip record X). Update the backend to use it.'` when server lacks live |
| Watch & Analyze card | card button | `'Watch & Analyze'`; detailed `'Watch a recorded rally while the server analyzes it frame by frame.'`, footnote `'You need: a recorded video file, in Chrome or the Windows app'`; short `'Play a video while it is analyzed.'` (mode_screen.dart:81-97) | Saves mode, opens Analyze | Disabled with `'Watch & Analyze is currently available in Chrome and Windows.'` (not web/Windows) or `'Update the backend to use video-driven live analysis.'` (server lacks watch_video) |
| "Last used" badge | data display | `'Last used'` (mode_screen.dart:48-49) | On the remembered mode's card | only if that mode is available |
| Change mode (page action used by Upload and Live) | button | `'Change mode'` with swap icon (mode_screen.dart:104-112) | Opens `/mode` | |

Responsive: CardGrid min 280 dp (detailed). Navigation out: `/`.

---

## 5. Upload (New analysis)

Purpose: pick a rally video, choose options and overlays, upload with progress. Files: `features/upload/upload_screen.dart`, `features/upload/upload_controller.dart`, shared fields `start_score_field.dart`, `match_setup_field.dart`, `stroke_model_field.dart`, `dependent_switch.dart`, `helper_text.dart`, `step_indicator.dart`. PageScaffold, max width 720.

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Title | data display | `'New analysis'` (upload_screen.dart:142) | | |
| Change mode | button | `'Change mode'` (upload_screen.dart:143) | `/mode` | |
| Step indicator | data display | `'1 Video'`, `'2 Options'`, `'3 Upload'` or `'3 Upload & calibrate'`; semantics `'Step N of 3: <step>'` (upload_screen.dart:145-148, step_indicator.dart:17, 38) | Step 0 no/bad file, 1 file chosen, 2 uploading | |
| Section 1 | card | `'1. Rally video'` (upload_screen.dart:151) | | |
| Drop zone (empty) | data display | `'Choose a rally video'`, `'Singles or doubles rally, MP4/MOV/AVI, up to 10 minutes. Best results from a phone on a tripod, elevated and behind the baseline.'` (upload_screen.dart:303-310) | Dashed outline (no real drag-and-drop) | no file |
| From gallery | button | `'From gallery'` (upload_screen.dart:121-126) | Video picker (gallery) | Android/iOS app only; disabled while uploading |
| Choose video | button | `'Choose video'` (upload_screen.dart:127-132) | File picker (mp4/mov/avi) | no file; disabled while uploading |
| File row | data display | file name; details `'m:ss · <size>'` plus `'longer than the 10-minute server limit'` / `'larger than the 1 GB server limit'` (upload_screen.dart:106-111, 158-163) | Details in error colour past a limit | file chosen |
| Replace | button | `'Replace'` (upload_screen.dart:134-138) | Re-pick | file chosen; disabled while uploading |
| Bad format | state | `'This file type is not supported. Use MP4, MOV or AVI.'` (upload_screen.dart:164-168) | | gallery pick with other extension |
| Section 2 | card | `'2. Options'` (upload_screen.dart:175) | | |
| Calibrate court | toggle | `'Calibrate court'`, `'Tap 4 court corners for player detection and court features. Recommended.'` (upload_screen.dart:179-187) | Upload then calibration screen | remembered |
| No-calibration warning | state | `'Without calibration players are not detected: Skeletons and Player boxes stay empty, and Court outline, Minimap, Speed, Scoreboard and the Referee layer are off.'` (upload_screen.dart:188-194) | amber helper | calibrate off |
| Referee layer | toggle (dependent) | `'Referee layer (beta)'`, `'Rally state and assisted scoreboard'`; blocked helper `'Turn on Calibrate court to enable'` (upload_screen.dart:195-207, dependent_switch.dart:31) | Turning on also selects the Scoreboard overlay | disabled while calibrate off |
| Game already under way | toggle + 2 dropdowns | `'Game already under way'`, `'Start the scoreboard from the score when recording began'`; dropdowns `'Near player'` / `'Far player'` (doubles: `'Near pair'` / `'Far pair'`), 0-29 (start_score_field.dart:68-90) | Errors `'Scores cannot be negative'`, `'That game is already over'` (start_score_field.dart:17-18) | calibrate + referee on; resets per file |
| Match setup | segmented + switch + dropdowns | `'Match'`: `'1 game'` / `'Best of 3'`; `'First server'`: `'Unknown'` / `'Near'` / `'Far'`; `'Lines'`: `'Singles'` / `'Doubles'` (match_setup_field.dart:65-118) | | calibrate + referee on |
| Change ends | toggle | `'Change ends'`; help `'By the rules: after each game, and at 11 in the deciding or only game. The score moves with the players.'` / `'Off: the score stays with each end. Use Players changed ends when they cross.'` (match_setup_field.dart:89-106) | | server >= 1.7 |
| Serves first / Receives first | dropdowns | `'Serves first'`, `'Receives first'`; items `'Not sure'`, `'Near player 1'`, `'Near player 2'`, `'Far player …'`; note `'Player 1 is the one on the left when play starts. With both set, the app follows who serves and receives each rally.'` (match_setup_field.dart:119-146) | | doubles + first server known |
| Overlays header | label + buttons | `'Overlays'`, `'All'`, `'None'` (upload_screen.dart:428-436) | Select all / none | |
| Overlay chips | chips (filter), grouped | groups `'Tracking'`, `'Players'`, `'Court'`, `'Match'`; chips `'Shuttle trail'`, `'Speed'`, `'Hit markers'`, `'Skeletons'`, `'Player boxes'`, `'Court outline'`, `'Minimap'`, `'Stroke labels'`, `'Scoreboard'` (upload_screen.dart:406-411, data/models/job.dart:347-357) | Disabled chip has tooltip with reason: `'Needs court calibration'`, `'Needs the referee layer'`, `'Not installed on this server'` (job.dart:320-327) | |
| Unavailable summary | state | `'Unavailable: <chip> (<reason>); …'` (upload_screen.dart:461) | | any chip disabled |
| Advanced | expansion | `'Advanced'`, subtitle `'Stroke model: <model or server default>'` (upload_screen.dart:224-241) | | hidden when server too old for model choice |
| Stroke model | segmented | `'Stroke model'`: `'CNN'`, `'LSTM'`, `'Random Forest'`, `'Ensemble'`; note per model (stroke_model_field.dart:9-14, 70-85); help `'Which classifier names each stroke. …'` / `'No stroke model is installed on this server, so strokes stay unnamed.'` / `'Not installed on this server: …'` (stroke_model_field.dart:50-59) | Not-installed models greyed | inside Advanced |
| Upload button | button | `'Upload and calibrate'` / `'Upload and analyze'` (upload_screen.dart:260-264) | Starts upload; then Calibration (calibrate on) or Processing | Disabled with helper `'Choose a video to continue'` / `'Choose an MP4, MOV or AVI file to continue'` (upload_screen.dart:112-116, 265) |
| Upload progress | state | semantics `'Upload progress'`; `'Uploading <sent> of <size> (NN%)'` (upload_screen.dart:246-257) | Replaces upload button | while uploading |
| Cancel upload | button | `'Cancel'` (upload_screen.dart:258) | Cancels | while uploading |
| Upload error | state | e.g. `'The upload failed. Try again.'`, `'Could not read the size of this file. Copy it to the device and try again.'`, `'This file is empty.'`, `'The browser version uploads at most 512 MB. …'` (upload_controller.dart:28-34, 256) | Error helper | |

Dialog: `'Long video'` / `'Large video'`, body "This clip is m:ss long / This file is X. The server accepts clips up to 10 minutes and 1 GB by default, and refuses longer ones after the upload. Trim it to the rally first.", buttons `'Cancel'` / `'Upload anyway'` (upload_screen.dart:74-93).
Behaviour: leaving the screen (not switching tabs) cancels the upload (upload_screen.dart:56-61). Options are remembered between sessions.
Responsive: single column, max 720. Navigation out: `/mode`, Calibration, Processing.

---

## 6. Watch & Analyze

Purpose: upload a video, then play it while the server analyses it (real time, or frame by frame), then save. File: `features/watch/watch_screen.dart` (+ `CornerCanvas` from calibration, `VideoDropZone` from upload, `HitBurstLayer`). PageScaffold, max width 900. One screen, three phases: pick, setup, running.

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Title | data display | `'Watch & Analyze'` (watch_screen.dart:799) | | |
| Change mode | button (text, no icon; separate implementation from ChangeModeButton) | `'Change mode'` (watch_screen.dart:802) | `/mode` | always |
| Unsupported | state | `'This backend does not support Watch & Analyze.'` (watch_screen.dart:806) | | server lacks watch_video |
| Drop zone | data display | as Upload (`'Choose a rally video'`…) | | no video |
| Choose video | button | `'Choose video'` / `'Uploading…'` (watch_screen.dart:810-814) | Picks and uploads at once (no progress bar, no cancel button) | disabled while uploading/detecting |
| File name | data display | filename (watch_screen.dart:818) | | setup phase |
| Playback and analysis card | card | `'Playback and analysis'` (watch_screen.dart:821) | | setup |
| Mode segmented | segmented | `'Real time'` / `'Analyze every frame'` (watch_screen.dart:827-836) | + help `'Video plays at normal speed while normalized frames are analyzed in the background.'` / `'Playback waits for every normalized frame. High-frame-rate videos may be sampled to a lower frame rate.'` (837-842) | disabled while scanning/detecting |
| Faster player analysis | toggle | `'Faster player analysis (experimental)'`, `'May miss players or change hits and results; not always faster. Requires calibrated court corners.'` (watch_screen.dart:843-854) | | real time + server watch_background |
| Background unsupported | state | `'Update the backend to use background analysis, or choose Analyze every frame.'` (watch_screen.dart:855-858) | | real time, no watch_background |
| Match format card | card | `'Match format'` (watch_screen.dart:864) | | |
| Manual / auto | segmented | `'Choose manually'` / `'Suggest automatically'` (watch_screen.dart:870-884) | Clears the chosen format | |
| Format chips | choice chips | `'Confirm the match format:'`, `'Singles'` / `'Doubles'` (watch_screen.dart:885-898) | Required before start | |
| Court calibration card | card | `'Court calibration'` + 5 help lines: `'Select the match format above, then find corners automatically or tap them manually.'`, `'Tap the four outer corners of the full court, … near left, near right, far right, far left. …'`, `'Blue lines preview the court markings. Adjust the corners until they match the video.'`, `'Without court calibration, player detection is disabled.'`, `'For best accuracy, use a tripod and keep the whole court in a fixed view; do not pan or zoom.'` (watch_screen.dart:904-934) | | |
| Find corners automatically | button | `'Find corners automatically'` / `'Finding court...'` (watch_screen.dart:913-923) | Server suggests corners; message `'Check the suggested outer court corners and drag them to adjust.'` or `'Could not find the court reliably. Place the corners manually.'` or `'<error>. Place the corners manually.'` (172-185) | needs a format; disabled while busy |
| Corner canvas | gesture | (see Calibration CornerCanvas) tap to add up to 4, drag handles, pinch/scroll zoom, loupe | Full-court preview lines once 4 corners valid (942-944) | 320 dp tall |
| Clear corners | button | `'Clear corners'` (watch_screen.dart:971-984) | | corners exist |
| Auto-detect card | card | `'Automatic detection requires four court corners and may be affected by spectators or hidden players.'` (watch_screen.dart:997-999) | | auto mode |
| Suggest match format | button | `'Suggest match format'` / `'Checking video…'` (watch_screen.dart:1000-1009) | Shows `'Suggested: <x>. <detail>'` or the detail (1014-1019) | 4 valid corners + server watch_match_type; unavailable text `'Automatic detection is unavailable on this server; choose manually.'` |
| Start analysis | button | `'Start analysis'` (watch_screen.dart:1025-1035) | Starts | needs format; real time needs watch_background; corners must be 0 or 4 valid |
| Video / frame view | video | - | Real time: media_kit video with box/shuttle overlay (only when analysis within 250 ms) and hit bursts; frame mode: analysed JPEG + overlay | running |
| Status card | data display | `'<status> ·N.N s / T s'`, `'Elapsed: hh:mm:ss (includes pauses)'`, `'Rally: <state>'`, latest hit (`'Stroke: x'` / `'Unclassified hit'`), `'Score: n – m'`, `'Line call: … (review)'`, top 3 coaching notes, `'Feedback may be delayed while the rally is confirmed. Playback is silent.'` (watch_screen.dart:1113-1128) | Status values: `'Connecting…'`, `'Starting analysis…'`, `'Opening video…'`, `'Playing in real time'`, `'Catching up…'`, `'Playing · background analysis'`, `'Playing'`, `'Paused'`, `'Confirming stop…'`, `'Saving…'`, `'Finishing analysis…'`, `'Rendering...'` / `'Rendering…'`, `'Session saved'`, `'Rendering failed'` | running |
| Diagnostics | data display | `'Demo server: results are synthetic and do not describe this video.'`, `'Tracking or pose models are unavailable on this server.'`, `'Analysis: X s · Preview: Y s. Overlays are hidden when analysis is behind.'`, candidate-filter lines, `'Experimental faster player analysis is active.'`, `'Faster analysis is unavailable; normal analysis is being used.'` (watch_screen.dart:1118-1139) | | as named |
| Configured analysis providers | expansion | `'Configured analysis providers'`; `'Detector: … · Pose: …'` (TensorRT RTX / CUDA / CPU / fallback) (watch_screen.dart:1140-1144, 81-97) | | started + server reports it |
| Play / Pause | button | `'Play'` / `'Pause'` (watch_screen.dart:1153-1175) | | running, no error, not stopping |
| Stop and save | button | `'Stop and save'` (watch_screen.dart:1176) | | same |
| View progress / saved | button | `'View analysis progress'` (background) / `'View saved session'` (watch_screen.dart:1179-1183) | Opens Processing for the job | job id known |
| Try again | button | `'Try again'` (watch_screen.dart:1184-1216) | Resets to setup with the same video | on error |
| Error | state | error text in error colour (watch_screen.dart:1218-1219), e.g. `'Connection lost. Check History for the analyzed portion.'`, `'Could not play this video. Try a supported MP4 or use frame-by-frame mode.'`, `'This video has no readable frames.'`, `'Could not confirm stop: …'` | | |

No dialogs or snackbars. Leaving the screen stops the analysis (dispose sends stop). Platform: web and Windows only (gated on Mode). Responsive: single column at all sizes.

---

## 7. Live

Purpose: camera preview, optional court calibration on a still, then the live scoring/coaching layout; stopping saves to History. Files: `features/live/live_screen.dart`, `features/live/widgets/live_view.dart`, `widgets/live_status.dart`, `widgets/live_coach_panel.dart`, `features/live/live_controller.dart`, `features/live/frame_source.dart`, plus `results/widgets/scoreboard.dart`, `court_minimap.dart`, `line_call_banner.dart`, `status_strip.dart`, `shared/widgets/courtside_tools.dart`, `hit_burst.dart`. Own Scaffold, max width 1400.

Phases (`live_controller.dart:19-29`): starting, ready, calibrating, connecting, live, reconnecting, stopping, saved, error.

### 7.1 Header (all phases)

| Element | Type | Exact label | What it does | Conditions |
|---|---|---|---|---|
| Title | data display | `'Live'` (live_screen.dart:79) | | |
| Cancel | button | `'Cancel'` (live_screen.dart:81-86) | Cancels connecting | connecting / reconnecting |
| Stop | button (red) | `'Stop'` (live_screen.dart:87-98) | Confirms then stops and saves | live / stopping; disabled while a decision is pending |
| Change mode | button | `'Change mode'` | `/mode` | other phases |
| Back / pop guard | behaviour | - | Back is blocked while streaming and opens the stop confirmation (live_screen.dart:50-58) | streaming |
| Snackbar notices | snackbar | controller notices, e.g. `'Not connected: the decision was not sent. Try again once live.'`, `'Decision unconfirmed. Check the score before trying again.'`, `'Could not send the decision. Check the connection and try again.'`, `'Stopped trying. What reached the server is saved to History in about a minute.'`, `'The server did not find that rally or call'`, refusal reasons `'Wait until the rally has ended, then award the point'`, `'The match is already won: Undo first to change the result'` (live_controller.dart:1023-1027, 1047, 1121-1146, 1248) | live_screen.dart:36-41 | |

### 7.2 Starting / error / saved

| Element | Type | Exact label | What it does | Conditions |
|---|---|---|---|---|
| Starting | state | `'Starting the camera…'` (live_screen.dart:106-109) | | starting |
| Error view | state | message = error, else `'Something went wrong'`; icon no-photography when permission denied (live_screen.dart:177-179) | Errors include `'Camera access was denied. Allow it in the system or browser settings, then retry.'`, `'No camera found on this device'`, `'Could not open the camera: …'` (frame_source.dart:64, 95-96), `'Cannot reach the live server at …'`, `'The live server did not answer'`, `'The server is busy with a job or another live session. Try again when it is done.'`, `'Camera orientation changed. …'`, `'Camera stopped: …'`, `'Lost the connection to the server. The session is saved to History once the server lets go of it (about a minute).'`, `'The server did not confirm the save. Check History for the session.'` | error |
| Try again | button | `'Try again'` (live_screen.dart:183-187) | Reopens camera | error |
| Open results | button | `'Open results'` (live_screen.dart:188-192) | Processing for saved job | error with a saved job |
| Open History | button | `'Open History'` (live_screen.dart:193-197) | History | error with a session id but no saved job |
| Saved view | state | `'Session saved to History. The annotated video is rendering.'` or `'No frames reached the server, so nothing was saved.'` (live_screen.dart:446-449) | | saved |
| Open results | button | `'Open results'` (live_screen.dart:455-460) | Processing (then auto to Results) | saved with job |
| New session | button | `'New session'` (live_screen.dart:461-465) | Reopens camera | saved |

Permission prompt: camera permission is requested by the OS/browser when the camera opens (frame_source.dart); denial shows the error view.

### 7.3 Ready

| Element | Type | Exact label | What it does | Conditions |
|---|---|---|---|---|
| Camera preview | video | - | 16:9, max 720 wide (live_screen.dart:333-351) | |
| Calibrate court | button | `'Calibrate court'` (live_screen.dart:223-227) | Takes a still, goes to calibrate | |
| Start without court | button | `'Start without court'` (live_screen.dart:228-237) | Starts with start score, no line calls | |
| Error line | state | error text (live_screen.dart:240-244), e.g. `'Could not take a picture: …'` | | |
| Before you start | card | `'Before you start'`; `'Put the <camera label> on a tripod, high and behind a baseline, with the whole court in view. Calibrate the court for the minimap, speed and line calls.'`, `'Without court calibration, player detection is disabled.'`, `'For best accuracy, keep the camera fixed and do not pan or zoom.'`, line-call disclaimer (live_screen.dart:246-263). Camera labels `'Back camera'`, `'Front camera'`, `'Webcam'`, `'Camera'` | | |
| Match setup | card | `'Match setup'` (live_screen.dart:264-296) with Game already under way, Match setup (Lines shown, Change ends if >= 1.7), Stroke model | Same fields as Upload §5 | |
| Games already won | 2 dropdowns | `'Games already won (starts in game N of 3)'`, `'Near player'`/`'Far player'` (pairs in doubles), 0/1 (start_score_field.dart:104-161) | | best of 3 + courtside (>= 1.5) |

Responsive: < 1000 dp wide: preview, buttons, tips, setup in one column; >= 1000: preview + buttons left, setup + tips in a 480 dp side panel (live_screen.dart:303-330).

### 7.4 Calibrate

| Element | Type | Exact label | What it does | Conditions |
|---|---|---|---|---|
| Corner diagram | data display | semantics `'Next corner: <name>'` / `'All corners set'` (calibration_screen.dart:325) | | |
| Instruction | data display | `'Tap the <Near left…> corner of the singles court (n of 4), also for doubles.'` / `'All 4 corners set. Drag to adjust, then go live.'` / `'The corners cross over. Drag them into order.'` (live_screen.dart:380-387) | | |
| Undo | button | tooltip `'Undo'` (live_screen.dart:389-393) | Removes last corner | corners exist |
| Corner canvas | gesture | handles `'<name> corner handle'` | on the still | |
| Back | button | `'Back'` (live_screen.dart:416) | Back to ready | |
| Go live | button | `'Go live'` (live_screen.dart:417-428) | Starts with corners | 4 convex corners |

No Reset button here (Calibration screen has one).

### 7.5 Connecting / live / reconnecting / stopping (LiveView)

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Video | video | - | Analysed frame + player boxes + speed-coloured shuttle trail (live_status.dart:106-146), falls back to raw preview | |
| Hit burst | overlay | `'SMASH!'`, `'POW!'` (clear), `'DROP!'`, `'TAP!'` (net shot), `'WHOOSH!'` (lift), `'SERVE!'`, `'HIT!'` (hit_burst.dart:16-22) | Comic burst on each hit, excluded from semantics | live with hits |
| Phase veil | state | `'Connecting… the server may be loading its models'`, `'Reconnecting…'`, `'Saving the session…'` (live_view.dart:128-133) | Dark veil over video | not live |
| Role switch | segmented | `'Referee'` / `'Coach'` (live_view.dart:164-176) | Switches the whole panel set | always |
| Status strip | chips | `'IN PLAY'` / `'BETWEEN RALLIES'` / `'–'`, `'Speed N km/h (est.)'`, `'Peak N km/h (est.)'`, `'Strokes N'` (status_strip.dart:22-37) | Strokes in current rally | |
| Match over card | card | `'Match won by <side>'`, `'Undo to change the result.'` (referee only), `'Stop and save'` (live_view.dart:184-204) | Opens stop confirmation | live + match over |
| Saving line | state | `'Saving the session to History…'` (live_view.dart:205-206) | live region | stopping |
| Pending / reconnect line | state | `'Reconnecting and refreshing the score…'` or pending action `'Saving the practice goal…'` / `'Confirming the interval timer change…'` / `'Confirming the referee decision…'` (live_view.dart:207-216, live_controller.dart:1097-1102) | live region | |
| Scoreboard | composite | see §10.8; live = large numerals, no rally history inside | Point Near/Far, Undo, `'Clear last winner'`, More menu, set service | Referee role (in Coach role a read-only scoreboard moves to the analysis column, live_view.dart:335) |
| Review count | data display | `'1 call awaiting review'` / `'N calls awaiting review'` (live_view.dart:218-221) | | referee + pending reviews |
| Review label / queue | data display / dropdown | `'Rally N · m:ss.s'` (live_view.dart:39, 222-238) | Dropdown to pick which call to review when > 1 | referee + reviews |
| Line call banner | banner | see §10.5 | Confirm/Call IN/OUT | referee |
| Interval panel | card + buttons | `'Interval · N s'` / `'Interval complete'` / `'Interval ended'`, `'Timer only. Play and scoring remain under referee control.'`, buttons `'Start'`, `'Pause'`, `'Resume'`, `'Reset'`, `'End'` (courtside_tools.dart:183-211) | Server-driven interval timer | referee + courtside depth (>= 1.6) + interval state |
| Decision history | expansion | see §10.9 (no seek in live) | | referee + courtside depth |
| Rally history | card | `'Rally history'`; empty `'Completed rallies appear here. Tap a selected winner to clear it.'` (live_view.dart:305-315) | Winner chips per rally (§10.8) | referee |
| Between-rally coaching | card | `'Between-rally coaching'` (live_coach_panel.dart:71) | | Coach role |
| Player filter | choice chips | `'Both'`, `'Near'`, `'Far'`, + `'Near 1'`, `'Near 2'`, `'Far 1'`, `'Far 2'` in doubles (courtside_tools.dart:7-43) | Filters notes and cues | Coach role |
| Pinned cue | card | `'Pinned practice cue · Rally N'`, cue text, `'Clear pin'` (live_coach_panel.dart:77-103) | | a cue pinned (local pin; without courtside depth) |
| Next rally cue | data display | `'Next rally'`; cue `'<Player>, <Stroke>: <tip>'` or `'Notes appear here after each rally.'` / `'Waiting for enough footage to suggest a cue.'` / `'Waiting for enough footage to suggest a cue for <side>.'` (live_coach_panel.dart:105-133) | live region | |
| Pin cue | button | `'Pin cue'` / `'Pinned'` (live_coach_panel.dart:35-45) | Pins locally, or saves as goal (source cue) with courtside depth | a cue exists |
| Set practice goal | button | `'Set practice goal'` (live_view.dart:256-262) | Opens goal dialog | courtside depth, no goal for this player |
| Practice goal card | card | `'Personal practice goal · <player>'` / `'Pinned practice cue · …'`, `'Completed · self-reported'` / `'Active goal'`, `'Not enough evidence to measure improvement on this goal.'`, buttons `'Mark complete'` / `'Reopen goal'`, `'Edit goal'` (courtside_tools.dart:256-301) | | courtside depth, goal saved |
| Last rally | data display | `'Last rally'`; `'Rally N · S strokes · D s · peak N km/h (est.) · landed X · <side> won'` (live_coach_panel.dart:137-151) | | after a rally |
| Focus so far | list | `'Focus so far'`; `'1. <note>'` with player colour bar (live_coach_panel.dart:152-180) | top 3 fixes | |
| Recent completed rallies | expansion | `'Recent completed rallies'`; `'Rally N · S stroke(s)'` + cue + Pin cue (live_coach_panel.dart:181-226) | last 3 rallies | |
| Coaching disclaimer | data display | kCoachingDisclaimer (shared/disclaimers.dart:2-4) | | Coach role |
| Live status bar | chips | `'Rally –'` / `'Rally N s'`, `'Latency –'` / `'Latency N ms'`, `'Sent N'` / `'Sent N · analysed M'`, `'Reduced quality'` (tooltip = reason or `'The server lowered the resolution to keep up'`), `'Demo server: synthetic rallies, not your camera'` / `'No shuttle tracking on this server'` / `'No pose model on this server'` (live_status.dart:53-99) | | |
| Waiting overlay note | state | `'Waiting for a fresh analysis overlay…'` (live_view.dart:330-331) | | live, waiting |
| Hit callout | data display | `'<Stroke> by <side> · N km/h (est.)'` (live_status.dart:17-31) | live region | hits exist |
| Court minimap | chart | see §10.7; highlights the landing of the call under review | | always |
| Recent strokes | card | `'Recent strokes'`; `'Detected strokes appear here during play.'`; rows `'m:ss.s · <side> · <Stroke>'`; `'Open the saved replay to jump to a stroke.'` (live_view.dart:344-361) | last 5 | |
| Keys hint | data display | `'Keys: N / F point near / far · Z undo · L let · I / O the call under review'` (live_view.dart:434-440) | | referee, **non-compact only** |

Keyboard shortcuts (referee role, phase live, no pending decision, ignored while typing in a text field; live_view.dart:363-399)

| Key | Action | Extra condition |
|---|---|---|
| N | point Near | match not over |
| F | point Far | match not over |
| Z or Ctrl+Z | undo | |
| L | let (replay last rally) | match not over, courtside >= 1.5, a rally exists |
| E | players changed ends | match not over, server >= 1.7 (not listed in the hint) |
| I / O | call IN / OUT on the call under review | a call needs review |

Dialogs: stop confirmation `'Stop and save this session?'`, `'The recording, score and calls are saved to History. The session cannot be continued afterwards.'`, `'Keep going'` / `'Stop and save'` (live_screen.dart:138-167; only when rallies, goals, decisions or corrections exist, else stops directly). Practice goal dialog `'Practice goal · <player or Both>'`, field `'What will you practise?'`, helper `'Personal goal; not a measured finding.'`, max 240, `'Cancel'` / `'Save goal'` (courtside_tools.dart:220-254). Retire confirmation (§10.8).

Responsive (live_view.dart:403-457): compact = one column: controls, (Coach: panel), camera, (Referee: rally history), analysis. Medium/expanded = two columns: controls + details + keys hint (flex 2) | camera + analysis (flex 3).

---

## 8. Calibration (upload flow)

Purpose: tap the 4 singles-court corners on a frame, then start processing (or skip). File: `features/calibration/calibration_screen.dart`. Own Scaffold, max width 1200.

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Title | data display | `'Court calibration'` (calibration_screen.dart:105) | Back button (stack) | |
| Undo | button | tooltip `'Undo'` (calibration_screen.dart:107-111) | Remove last corner | corners exist |
| Reset | button | tooltip `'Reset'` (calibration_screen.dart:112-116) | Clear corners | corners exist |
| Skip (header) | button | `'Skip'` (calibration_screen.dart:118, 192-195) | Creates job without corners (drops court overlays and referee) | **expanded only**; disabled while submitting |
| Skip (below) | button | `'Skip'` (calibration_screen.dart:188) | same | compact + medium |
| Corner diagram | data display | semantics `'Next corner: <name>'` / `'All corners set'` | Court sketch, next corner highlighted | |
| Instruction | data display | `'Tap the <name> corner of the singles court (n of 4), also for doubles. Pinch or scroll to zoom.'` / `'All 4 corners set. Drag a corner to adjust, then start.'` / `'The corners cross over. Drag them so they go around the court in order: near left, near right, far right, far left.'` (error colour) (calibration_screen.dart:242-255) | Names `'Near left'`, `'Near right'`, `'Far right'`, `'Far left'` (:19) | |
| Corner checklist | list | `'1. Near left'` … with check / ring icons (calibration_screen.dart:280-311) | | **expanded only** |
| Frame canvas | gesture | handles semantics `'<name> corner handle'` (calibration_screen.dart:480) | Tap adds a corner (max 4, not on a handle); drag handle moves it with a 2.5x loupe magnifier; pinch / scroll zoom up to 6x; numbered coloured markers + outline | |
| Frame unavailable | state | `'Frame unavailable'` (calibration_screen.dart:467-468) | | image load fails |
| Frame slider | slider | `'Frame'`; value label `'N.N s'`; semantics `'Frame N'` (calibration_screen.dart:216-236) | Picks the frame shown (fetched on drag end) | video has > 1 frame |
| Help | data display | `'Skipping calibration disables player detection. For best accuracy, use a fixed camera and keep the whole court visible.'` (calibration_screen.dart:257-261) | | |
| Error | state | API error text (calibration_screen.dart:264-268) | | after failed start |
| Start processing | button | `'Start processing'` (calibration_screen.dart:270-274) | Creates job with corners, opens Processing | 4 convex corners, not submitting |

States: video loading spinner; video error MessageView with the error (calibration_screen.dart:124-126).
Responsive: expanded = frame card left, 320 dp side card (diagram 96x128, instruction, checklist, help, start). Compact/medium = diagram + instruction row, frame, help, start, Skip below.

---

## 9. Processing

Purpose: per-stage job progress, then on to Results; cancel / retry. File: `features/processing/processing_screen.dart`. PageScaffold.

| Element | Type | Exact label | What it does / shows | Conditions |
|---|---|---|---|---|
| Title | data display | `'Processing'` (processing_screen.dart:113, 156) | | |
| Loading | state | skeleton card (processing_screen.dart:112-132) | | job loading |
| Job gone | state | `'This job no longer exists'`, `'It was cancelled or deleted.'`, button `'Back to upload'` (processing_screen.dart:135-144) | Opens `/` | 404; this state has a Material AppBar `'Processing'` |
| Lost connection | state | `'Lost connection to server'`, `'<error>\nThe job keeps running on the server.'`, `'Retry'` (processing_screen.dart:145-153) | Refetch | other errors; AppBar |
| Header | data display | file name or `'Live session'` / `'Analysis'`; status `'Waiting in queue (position N)'`, `'Running: <stage>'`, `'Done'`, `'Failed'`, `'Cancelled'` (processing_screen.dart:287-293, 313-318) | Icon video/movie | |
| Percent | data display | `'NN%'` (processing_screen.dart:322) | | |
| Cancel | button | `'Cancel'` (processing_screen.dart:166-169) | Confirmation dialog then delete job, go to `/` | unfinished |
| Overall progress | progress bar | semantics `'Overall progress'` (processing_screen.dart:327) | | |
| Timing | data display | `'Elapsed 1 min 05 s · about 42 s left'` (processing_screen.dart:296-300, 32-37) | | elapsed when not queued; ETA when running |
| View results | button | `'View results'` (processing_screen.dart:201-205) | Results | done (reached by Back from Results) |
| Back to upload | button | `'Back to upload'` (processing_screen.dart:209, 236-239) | `/` (whatever the Analyze mode is) | cancelled, failed |
| Failure text | state | job error or `'Processing failed'` (processing_screen.dart:213-216) | | failed |
| Try again | button | `'Try again'` (processing_screen.dart:231-235) | New job with same video, options, corners | failed and no results |
| View results (failed) | button | `'View results'` (processing_screen.dart:225-229) | | failed live session with a record |
| Stage rows | list | `'Load video'`, `'Track shuttle'`, `'Players and pose'`, `'Court mapping'`, `'Detect hits'`, `'Classify strokes'`, `'Form feedback'`, `'Speed and stats'`, `'Rally and score'`, `'Render video'` (processing_screen.dart:19-30); trailing raw status text (`done`, `running`, `failed`, `skipped`, `pending`) (:363) | Icon per status; thin progress bar on the running stage | |
| Notify me when done | toggle | `'Notify me when done'`, `'If the app is in the background when the job ends'` (processing_screen.dart:176-182) | Same setting as Settings | unfinished |
| Results preview | card (skeleton) | `'Results'`, `'Ready when processing finishes'` (processing_screen.dart:251-271) | | unfinished |

Dialog: `'Cancel processing?'`, `'The job stops and its partial results are deleted.'`, `'Keep'` / `'Cancel job'` (processing_screen.dart:45-59).
Snackbars: `'Could not cancel: <e>'` (:66); retry failure `'<e>'` (:79).
Auto navigation: when a fresh poll says done and this page is on top, go to Results (processing_screen.dart:100-107). Background completion triggers a system notification (§0).
Responsive: single column. Navigation out: Results, `/`.

---

## 10. Results

Purpose: annotated playback with stroke timeline, minimap, status, score, coach notes, downloads. Files: `features/results/results_screen.dart`, `features/results/downloads.dart`, `features/results/widgets/*.dart`, `features/coach/coach_report_card.dart`, `shared/widgets/courtside_tools.dart`, `shared/widgets/hit_burst.dart`, `shared/widgets/shuttle_speed.dart`. Own Scaffold, max width 1400.

### 10.1 Page frame

| Element | Type | Exact label / tooltip | What it does / shows | Conditions |
|---|---|---|---|---|
| Title + sub-line | data display | `'Results'`; below: `'<file> · <yyyy-mm-dd hh:mm>'` (results_screen.dart:66-68, 83-87) | Back button (to Processing) | |
| Change overlays | button | tooltip `'Change overlays'` (results_screen.dart:132-137) | Opens re-render sheet | job loaded |
| Download or share | menu | tooltip `'Download or share'`; items `'Annotated video (MP4)'`, `'Summary (JSON)'`, `'Hits (CSV)'`, `'Rallies (CSV)'` (results_screen.dart:138-155, downloads.dart:12-16) | Item disabled when the job says that output is missing. Web: opens in browser; desktop: save dialog `'Save <file>'`; phone: temp file + share sheet (downloads.dart:34-38, 49-63) | |
| Stats row | data display (4 tiles) | `'Strokes'`, `'Rallies'`, `'Peak speed'` (`km/h`), `'Clip length'` (results_screen.dart:172-181) | Tile only when the record has that number | **not compact**, and window height >= 640 (results_screen.dart:72, 160) |
| Loading | state | skeleton in the layout's shape (results_screen.dart:197-233) | | record loading |
| Error | state | `'Could not load results'`, error detail, `'Retry'` (results_screen.dart:94-102) | | record error (a failed refresh keeps old data) |

Snackbars: `'Preparing <file label>…'`, `'Saved <path>'`, `'Download failed: <e>'` (results_screen.dart:46-53); score/line-call change failures `'<e>'` (:446, :486); `'No rally to replay yet. Move to the rally first.'` (:402-404); `'Could not save goal: <e>'` (:602); re-render failure `'<e>'` (:252).
Sheet (re-render): `'Overlays'`, all 9 overlay chips (disabled ones with reason tooltip), `'Re-render video'` (results_screen.dart:236-314); on confirm the job re-renders and the app goes to Processing.

### 10.2 Layout (results_layout.dart)

| Window | Arrangement |
|---|---|
| compact (< 600) | video card + status (scroll, flex 3), then pill tabs `'Timeline'`, `'Minimap'`, `'Score'`, `'Coach'` (flex 2) (results_layout.dart:73-111, 148-161) |
| landscape phone (height < 500 and wider than tall) | video + status left (scroll), the same tabs right (results_layout.dart:40-42, 135-144) |
| medium (600-1023) | left: video (flex 3), status, timeline (flex 2); right panel 30% (300-400 dp, max 40%): minimap, coach, scoreboard (scroll) (results_layout.dart:164-185) |
| expanded (>= 1024) | top row: video + status | side panel (minimap, coach, scoreboard); full-width timeline below (results_layout.dart:187-213) |

The minimap is sized so the whole court fits without scrolling (`CourtMaxHeight`, results_layout.dart:115-119).

### 10.3 Video panel and playback controls (video_panel.dart)

| Element | Type | Exact label / tooltip | What it does | Conditions |
|---|---|---|---|---|
| Video | video | semantics `'Annotated rally video'` (video_panel.dart:42-51) | media_kit `Video` with its **default built-in controls** (play, seek bar, fullscreen; exact set is platform-dependent and not in app code) | output video exists |
| Hit burst overlay | overlay | comic words (§7.5) | Plays as playback passes each hit (results_screen.dart:533-537) | |
| Spinner | state | - | | job loading or video opening |
| No video | state | `'Annotated video not available'`, `'The render stage did not produce a video for this job.'` (video_panel.dart:53-57) | | render produced no video |
| Previous frame | button | tooltip `'Previous frame (Left arrow)'` (video_panel.dart:131-135) | Pause, step back one frame | video available |
| Play / Pause | button | tooltip `'Play (Space)'` / `'Pause (Space)'` (video_panel.dart:141-145) | | video available |
| Next frame | button | tooltip `'Next frame (Right arrow)'` (video_panel.dart:148-152) | | video available |
| Speed | segmented | `'0.25×'`, `'0.5×'`, `'1×'`; tooltips `'0.25× speed'`, `'0.5× speed'`, `'1.0× speed'` (video_panel.dart:153-162) | Playback rate | video available |

Keyboard shortcuts (whole Results screen, only while no inner control has focus; video_panel.dart:171-201): **Space** play/pause, **Left** previous frame, **Right** next frame.
Seeking: timeline / note / citation seeks land 0.5 s before the moment (stroke_timeline.dart:8). Without a video, seeking moves the minimap, status and score to that frame instead (results_screen.dart:458-466).

### 10.4 Status strip (status_strip.dart)

Chips: rally state `'IN PLAY'` / `'BETWEEN RALLIES'` / `'–'`; `'Speed N km/h (est.)'`; `'Peak N km/h (est.)'`; `'Strokes N'` (strokes so far) (status_strip.dart:21-37). Always shown under the video.

### 10.5 Line-call banner and review (line_call_banner.dart)

| Element | Type | Exact label | What it does | Conditions |
|---|---|---|---|---|
| Banner | banner | big word `'IN'` / `'OUT'` / `'UNCERTAIN'`; detail `'Automated call · NN% confidence · M cm inside/outside the line · Confirmed by referee · looks IN/OUT, please confirm'`; semantics `'Line call <word>. <detail>'` (live region) (line_call_banner.dart:43-55) | Coloured by call | within 3 s after a landing, or the earliest call still needing review (line_call_banner.dart:7-24) |
| Confirm / Call buttons | buttons | `'Confirm IN'` / `'Confirm OUT'` (uncertain, matching the guess), else `'Call IN'` / `'Call OUT'` (line_call_banner.dart:77-87) | Override on server; re-scores | uncertain: both; reviewed: only the opposite call; disabled while busy |

### 10.6 Stroke timeline (stroke_timeline.dart)

| Element | Type | Exact label / tooltip | What it does | Conditions |
|---|---|---|---|---|
| Empty | state | `'No hits detected yet'`, `'Hits and strokes appear here once those pipeline stages are in place.'` (stroke_timeline.dart:64-69) | | no hits |
| Player filter | choice chips | `'Both'`, `'Near'`, `'Far'` (stroke_timeline.dart:80-88) | Filter by side (doubles partners count under their side) | |
| Stroke filter | menu | tooltip `'Filter by stroke'`; chip `'All strokes'` / stroke name; items `'All strokes'` + strokes present (stroke_timeline.dart:90-103) | | |
| No match | state | `'No hits match the filter'` (stroke_timeline.dart:109) | | |
| Hit row | list row | avatar `N`/`F`/`N1`…; title `'<Stroke>'` or `'<Stroke> ?'` (uncertain) or `'Unclassified'`; subtitle `'NN% · ~N km/h (est.) · <tip>'`; time `'m:ss.s'`; semantics `'<side> player, <Stroke> at m:ss.s'`, hint `'Double tap to jump to this hit. Long press for details.'` (stroke_timeline.dart:141-189) | Tap: seek; long press: details | auto-scrolls to the current hit; current row selected |
| Details button | button | tooltip `'Details'` (stroke_timeline.dart:182-186) | Opens hit details sheet | |

Hit details bottom sheet (stroke_timeline.dart:195-265): title `'<Stroke> · <side> player · m:ss.s'`; `'Low confidence: the model is unsure about this stroke.'` (uncertain); top 3 class probabilities as bars; `'Form feedback'` with each rule pass/fail (semantic `'passed'` / `'failed'`) and tip; `'No rules could be checked for this hit.'`; `'Heuristic guidance, not professional coaching.'`.

### 10.7 Court minimap and heatmap (court_minimap.dart, shuttle_speed.dart)

| Element | Type | Exact label / tooltip | What it does | Conditions |
|---|---|---|---|---|
| Card | card | `'Court'` (court_minimap.dart:149) | | |
| Heatmap | toggle (filter chip) | `'Heatmap'`; tooltip `'Show time spent by each player during play'` / `'Show time spent by each pair during play'` (court_minimap.dart:151-158) | Overlays time-in-cell heat per side | calibrated record only |
| Court picture | chart | semantics: `'Top-down court. Near player at X m across, Y m up the court. …'` (doubles variant with 4 players), shuttle `(rally estimate / camera projection)`, `'Highlighted landing for rally N.'`, heat description `'Heatmap: near player mostly at …'` (court_minimap.dart:164-170, 229-248, 448-459) | Players, shuttle trail coloured by speed, hit marks of the rally, landings, review landing (live), doubles alleys | calibrated |
| Speed legend | data display | `'Estimated shuttle speed (km/h)'`, `'<30'`, `'30–<60'`, `'60–<100'`, `'100+'` (shuttle_speed.dart:68-74) | | calibrated |
| Not calibrated | state | `'Calibrate the court when uploading to see player and shuttle positions.'` / live: `'Calibrate the court before going live to see player and shuttle positions.'` (court_minimap.dart:216-221) | | no corners |

### 10.8 Scoreboard, rally history, decision menu (scoreboard.dart, game_service_prompt.dart)

| Element | Type | Exact label / tooltip | What it does | Conditions |
|---|---|---|---|---|
| Card | card | `'Score and stats'` (scoreboard.dart:125) | | |
| No referee | state | `'Enable the referee layer to keep score.'` (scoreboard.dart:130) | | no score in record |
| Game line | data display | `'Game N of 3 · games a–b'` (scoreboard.dart:132-137) | at the playback position | best of 3 |
| Finished games | data display | `'G1 21–17 · G2 …'` (scoreboard.dart:139-148) | | games finished |
| Ends changed | data display | `'Ends changed: Near and Far are the ends as they are now'` (scoreboard.dart:149-155) | | ends swapped at that moment |
| Score | data display | `'Near'` / `'Far'` + points, serving icon; semantics `'Score: near N, far M. <who> serves from the <left/right> court to <who>'` (scoreboard.dart:156-189, 517-567) | Larger in live | |
| Doubles service | data display | `'Near 1 serves to Far 2'` (scoreboard.dart:191-196) | | doubles with known ids, at end |
| Match state chips | chips | `'Match won by <side>'` / `'<side> wins'` + `' (retired)'`; `'<side> serves · <left/right> court'`; `'Match point <side>'`; `'Game point <side>'` (scoreboard.dart:375-401) | | at end of record |
| Notice | state | `'Change ends'`, `'Interval: up to N s'`, `'Interval (N s): change ends'` / `'Interval: change ends'` (scoreboard.dart:403-441) | live region | |
| Who serves first (doubles) | card + dropdowns + button | `'Who serves first in game N?'`, `'<side> won the game and serves first. Pick the server and receiver so the app can follow the service order.'`, `'Serves'` / `'Receives'` (hint `'Choose'`), `'Set service'` (game_service_prompt.dart:65-93) | | doubles, game >= 2, server unknown, match not over |
| Point Near / Point Far | buttons | `'Point Near'` / `'Point Far'` (scoreboard.dart:215-234) | Award point at playback position (D21) | disabled busy or match over |
| Undo | button | `'Undo'` (scoreboard.dart:240-251) | Take back newest score change or line-call override | disabled when nothing to undo or busy |
| Clear last winner | button | `'Clear last winner'` (scoreboard.dart:252-256) | | **live only** |
| More (decision menu) | menu | `'More'`; tooltip `'More referee decisions'` (scoreboard.dart:612-662) | Items: `'Fault by Near (point Far)'`, `'Service fault by Near (point Far)'` (and Far), `'Let: replay the last rally'`, `'Players changed ends'`, `'Near retires'`, `'Far retires'` (scoreboard.dart:629-650) | courtside >= 1.5 for fault/let/retire; let needs a rally; change ends needs >= 1.7; disabled busy / match over |
| Busy bar | state | linear progress (scoreboard.dart:272) | | busy |
| Rally rows | list + choice chips | `'G1 · Rally N · S strokes · in / out / in ? / no landing call'`; chips `'Near'` / `'Far'`; tooltips `'Rally N won by the near player'` / `'…; tap to clear'` (pair in doubles) (scoreboard.dart:468-511) | Tap: set winner; tap selected: clear (undecided) | Results: shown inside scoreboard |
| Let chip | chip | `'Let'`, tooltip `'Let: the rally is replayed'` (scoreboard.dart:485-489) | | rally cleared as a let |
| Undecided marker | icon | tooltip `'Undecided: pick the winner'` (scoreboard.dart:490-494) | | no winner, not a let |
| Corrections summary | data display | `'N correction(s) · N point(s) awarded · retired · N change(s) of ends'` (scoreboard.dart:349-360) | | corrections exist |
| Stroke counts | list | `'<Stroke>'` + count (scoreboard.dart:283-292) | | summary has strokes |

Dialog (retire): `'<side> retires?'`, `'<other> wins the match. Rallies after this do not count. Undo takes it back.'`, `'Cancel'` / `'Retire'` (scoreboard.dart:591-608).

### 10.9 Decision history (courtside_tools.dart:45-132)

Expansion `'Decision history (N)'`; empty `'New referee decisions appear here. Older records may have no audit history.'`; game filter dropdown `'All games'` / `'Game N'`; filter chip `'Undone only'`; count `'N of M decisions'` / `'No matching decisions'`; entries title `'<server detail> · Undone'`, subtitle `'Game N · Rally N · a–b\n<local time>'`, play icon + tap to seek when a video exists. Under the scoreboard in Results; in Live only with courtside depth (no seek).

### 10.10 Summary chart (summary_chart.dart)

Card `'Strokes by player'`; `'Strokes named by the <CNN|LSTM|Random Forest|Ensemble> model'`; grouped bar chart per stroke class, one bar per player (4 in doubles); legend `'<side>: N hits, peak N km/h (est.)'`; semantics lists counts. Hidden when no hits. Placed under the scoreboard + decision history.

### 10.11 Session summary / Coach panel (session_summary.dart)

| Element | Type | Exact label / tooltip | What it does | Conditions |
|---|---|---|---|---|
| Card | card | `'Coach'` (session_summary.dart:96) | Compact: the Coach tab; otherwise in the side panel between minimap and scoreboard | |
| Recap | data display | `'Session recap'`, `'Match won by <side>'`, `'Games won: a–b'`, `'Session stroke totals'` chips `'<Stroke>: N'` (session_summary.dart:100-114) | | as data allows |
| Player filter | choice chips | `'Both'`, `'Near'`, `'Far'` (+ doubles partners) | Filters notes and goals | attributed notes/goals exist |
| Practice goals | cards | PracticeGoalCard (§7.5): `'Mark complete'` / `'Reopen goal'`, `'View moment'` (no Edit here) | Completion saved to server | complete button only when record >= 1.6; View moment when video and valid frame |
| Top things to fix | list | `'Top things to fix'`; ranked notes with moment chips (session_summary.dart:132-135) | | notes exist |
| Empty notes | state | `'No repeated pattern was identified for <side>.'` / `'Session notes appear once strokes are classified.'` / `'Not enough evidence of a repeated pattern in this session.'` (session_summary.dart:123-131) | | |
| More player notes | expansion | `'More player notes (N)'` (session_summary.dart:136-141) | | |
| Session-wide | list | `'Session-wide notes and goals'` (session_summary.dart:142-146) | | |
| Moment chips | chips | label = moment label (`'m:ss.s'`), tooltip `'Play from <label>'` (session_summary.dart:212-231) | Seek | video available |
| Coaching report | card | see below | | |
| Ask your coach | button | `'Ask your coach'` (session_summary.dart:149-153) | Opens Chat | disabled when chat unavailable |
| Chat off note | state | `'Coach chat is off on this server (no Gemini or Claude API key). Notes still work.'` (session_summary.dart:154-161) | | chat unavailable |
| Disclaimer | data display | kCoachingDisclaimer | | |

Coaching report card (coach_report_card.dart): title `'Coaching report'`; refresh button tooltip `'Write the report again'` (spinner while busy) (:52-67); loading `'Writing your coaching report…'` (:81); error text (:75-78); body: summary, `'Built from the session notes (no AI provider answered).'`, `'Strengths'`, `'To work on'` (title, evidence, `'Drill: …'`, moment chips), `'Drills'` (expansion per drill: name, purpose, how), `'Next session'` (:105-155).

---

## 11. Per-job Chat

Purpose: ask the AI coach about one session; history saved on the server. File: `features/chat/chat_screen.dart`, `features/coach/source_chips.dart`. Own Scaffold, max width 900.

| Element | Type | Exact label / tooltip | What it does | Conditions |
|---|---|---|---|---|
| Title | data display | `'Ask your coach'` (chat_screen.dart:185) | Back to Results | |
| Unavailable | state | `'Checking the server…'` / `'Coach chat is off on this server'`; detail `'The server owner has not set a Gemini or Claude API key. Session notes in the Coach tab still work.'` + privacy text (chat_screen.dart:188-197) | | chat unavailable |
| Privacy note | data display | kChatPrivacy (disclaimers.dart:7-11) | | |
| Empty intro | state | `'Ask about your strokes, rallies, line calls or what to work on. Answers come only from this session\'s data.'` (chat_screen.dart:207-212) | | no messages |
| Suggested questions | chips | `'What should I fix first?'`, `'Why did my smashes land short?'`, `'How did I lose my rallies?'` (chat_screen.dart:109-113) | Sends the question | no messages |
| Bubbles | data display | semantics `'You asked'` / `'Coach answered'`; selectable text; streaming shows `'…'` (chat_screen.dart:229-236, 376-382) | | |
| Citation chips | chips | `'m:ss.s'`, tooltip `'Play from …'` | Sets seek request, goes to Results and plays there | answer has citations |
| Source chips | chips | short title, tooltip full title; semantics `'Sources'` (source_chips.dart:51-69) | Opens source dialog | answer cited knowledge base |
| Error | state | e.g. `'The coach could not answer'`, `'The answer was cut off. Try asking again.'`, API message (chat_screen.dart:81, 86, 90-92, 237-244) | Failed question is put back in the box | |
| Question box | field | hint `'Your question'` / `'Question limit for this session reached'`, max 1000 (chat_screen.dart:265-285) | Enter sends | disabled while busy or at limit |
| Send | button | tooltip `'Send'` (chat_screen.dart:288-297) | | disabled busy / at limit; spinner busy |
| Disclaimer + counter | data display | kCoachingDisclaimer; `'N of LIMIT'` (chat_screen.dart:311-325) | | counter when server sets a limit |

Source dialog: title = source title, excerpt / reference / edition, `'Open reference'` (https only) and `'Close'`; snackbar `'Could not open reference.'` (source_chips.dart:16-48).

---

## 12. Coach (general)

Purpose: general AI coach (technique, rules, progress across sessions); conversation lives in the app only. File: `features/coach/coach_screen.dart`. Outside the shell, Material AppBar.

| Element | Type | Exact label / tooltip | What it does | Conditions |
|---|---|---|---|---|
| AppBar title | data display | `'Coach'` (coach_screen.dart:151) | Back arrow (pushed route) | |
| New conversation | button | tooltip `'New conversation'` (coach_screen.dart:153-158) | Clears turns | turns exist; disabled busy |
| Unavailable | state | `'Checking the server…'` / `'The coach is off on this server'`, `'The server owner has not set a Gemini (or Claude) API key.'` + kCoachPrivacy (coach_screen.dart:162-170) | | chat unavailable |
| Privacy | data display | kCoachPrivacy (disclaimers.dart:14-17) | | |
| Intro | state | `'Ask about technique, tactics, drills, the rules, or how you are progressing across your recorded sessions.'` (coach_screen.dart:185-189) | | no turns |
| Suggestions | chips | `'Am I improving across my sessions?'`, `'When should I split step?'`, `'How does doubles rotation work?'`, `'What are the service rules?'` (coach_screen.dart:97-102) | Send | no turns |
| Bubbles | data display | `'You asked'` / `'Coach answered'`, source chips (coach_screen.dart:269-305) | Different styling from Chat (Card, no citations) | |
| Error | state | as Chat | | |
| Question | field | label `'Your question'` (coach_screen.dart:226-238) | Outlined field (not the rounded bar used by Chat) | disabled busy |
| Send | button | tooltip `'Send'` (coach_screen.dart:241-250) | | |
| Disclaimer | data display | kCoachingDisclaimer | | |

Conversation is kept for the app lifetime (coach_screen.dart:92-95); last 12 turns sent as history.

---

## 13. History

Purpose: past jobs on the server: search, filter, sort, open, delete. File: `features/history/history_screen.dart`. Own Scaffold, max width 720.

| Element | Type | Exact label / tooltip | What it does | Conditions |
|---|---|---|---|---|
| Title + updated | data display | `'History'`, `'Updated hh:mm'` (history_screen.dart:91-93) | | after a load |
| Ask the coach | button | tooltip `'Ask the coach'` (history_screen.dart:95-99) | Pushes `/coach` (only entry point to the general coach) | |
| Refresh | button | tooltip `'Refresh'` (history_screen.dart:100-104) | Refetch | |
| Pull to refresh | gesture | - (history_screen.dart:161-162) | Refetch | list shown |
| Loading | state | 5 skeleton rows (history_screen.dart:124-135) | | |
| Error | state | `'Could not load jobs'`, error, `'Retry'` (history_screen.dart:136-144) | | |
| Empty | state | `'No analyses on this server yet'`, `'Upload a clip or run a live session. Finished analyses and saved live sessions appear here.'`, `'Start an analysis'` (history_screen.dart:146-158) | Opens `/` | no jobs |
| Search | field | hint `'Search by file name'` (history_screen.dart:194-204) | Filters by file name or job id; shared with top-bar search | |
| Mode filter | segmented | `'All'` / `'Upload'` / `'Live'` (history_screen.dart:205-214) | | |
| Sort | button | `'Newest first'` / `'Oldest first'` (history_screen.dart:215-219) | Toggles | |
| No match | state | `'No analyses match.'` (history_screen.dart:168-174) | | |
| Job tile | list row | title = file name or `'Analysis <id>'`; status pill; `'Live|Upload · Doubles|Singles · <date> · <stage> NN% · <id>'`; icon semantics = status name (history_screen.dart:273-330) | Tap: Results / Processing; finished without record shows snackbar | |
| Delete | button | tooltip `'Delete'` (history_screen.dart:341-348) | Delete dialog | |
| Swipe to delete | gesture | red background, delete icon (history_screen.dart:276-289) | Right-to-left swipe opens the same dialog | |

Dialog: `'Delete analysis?'`, `'The results are removed from the server.'`, checkbox `'Also delete the uploaded video'` / `'and every analysis of it'`, `'Cancel'` / `'Delete'` (history_screen.dart:383-409).
Snackbars: `'Could not delete: <e>'` (:264), `'This job has no results on the server any more.'` (:334-336).
Responsive: controls wrap. Navigation out: Results, Processing, `/`, `/coach`.

---

## 14. Settings

Purpose: connection, theme, notifications, privacy, about. File: `features/settings/settings_screen.dart`. PageScaffold.

| Element | Type | Exact label | What it does | Conditions |
|---|---|---|---|---|
| Title | data display | `'Settings'` (settings_screen.dart:30) | | |
| Connection card | card | `'Connection'`; URL or `'Not connected'` (settings_screen.dart:33-37) | | |
| Status pill + detail | data display | `'Checking…'` / `'Offline'` / `'Online'`; detail error message or `'v<ver> · schema <x> · <DEVICE>'` (settings_screen.dart:44-56) | | |
| Test connection | button | `'Test connection'` (settings_screen.dart:64-68) | Re-checks health | |
| Change server | button | `'Change server'` (settings_screen.dart:71-78) | Clears saved server (no confirmation) and opens Connect | |
| Appearance | segmented | `'Appearance'`: `'System'`, `'Light'`, `'Dark'` (settings_screen.dart:85-107) | Theme mode (only place to choose System; only theme control on compact) | |
| Notifications | toggle | `'Notify when an analysis finishes'`, `'Only while the app is in the background'` (settings_screen.dart:110-118) | | |
| Privacy & data | bullets | `'Videos and live camera frames go only to your ShuttleSense server.'`, `'Coach chat sends a text summary of a session and your questions to the Claude API. No video, frames or images are sent.'`, `'Delete an analysis, or its video too, from History.'` (settings_screen.dart:121-131) | | |
| Coach chat pill | data display | `'Coach chat: on'` / `'Coach chat: off'` (settings_screen.dart:137-140) | | |
| How to enable | button | `'How to enable'` (settings_screen.dart:141-151) | Info dialog | chat off |
| About | data display | `'ShuttleSense analyzes badminton singles and doubles rallies: shuttle tracking, pose, stroke classification and court analytics. Speed, in/out and score are estimates.'` (settings_screen.dart:163-167) | | |
| Disclaimer | button | `'Disclaimer'` (settings_screen.dart:173-178) | Dialog with line-call note + coaching disclaimer | |
| Licenses | button | `'Licenses'` (settings_screen.dart:179-184) | Flutter license page | |

Dialogs: `'Turning on coach chat'` (mentions `SHUTTLESENSE_ANTHROPIC_API_KEY` and kChatPrivacy), `'Disclaimer'`; both with `'OK'` (settings_screen.dart:143-149, 195-202).

---

## 15. Styleguide

Purpose: design tokens and shared components gallery, reviewable without a server. File: `features/styleguide/styleguide_screen.dart`. Outside the shell; only reachable by typing `/styleguide`.

Contents: title `'Styleguide'`, local `'Light'` / `'Dark'` segmented (preview only, does not change app theme), `'ShuttleSense design tokens and shared components.'`; the three mode cards (`'Upload clip'` with `'Last used'`, `'Go live'`, `'Watch & Analyze'`); cards `'Colour'` (swatches), `'Type'` (`'Outfit'`), `'Buttons'` (`'Primary'`, `'Secondary'`, `'Outlined'`, `'Ghost'`, `'Disabled'`, bell icon `'Notifications'`, `'Show toast'` -> snackbar `'Analysis finished'`, `'Show dialog'` -> `'Delete this analysis?'`), `'Controls'` (Singles/Doubles, Calibrate court switch, Trail/Speed/Hits chips, disabled Scoreboard chip with tooltip `'Turn on Referee layer to enable'`, `'Server address'` field), `'Stats'`, `'Lists and progress'`, `'Status'` (pills, helper texts, dependent switch), `'Empty state'`, `'Error and loading'` (styleguide_screen.dart:60-316). Inert samples, no features.

---

## 16. Not found

`core/router/app_router.dart:55-77`. Outside the shell. Header `'Page not found'` (no back), MessageView `'Page not found'`, `'Nothing lives at <uri>.'`, button `'Go to Home'` -> `/dashboard`.

---

## 17. Cross-screen summary

### Dialogs
| Screen | Title | Buttons |
|---|---|---|
| Connect | `'Different data format'` | `'Cancel'`, `'Connect anyway'` |
| Upload | `'Long video'` / `'Large video'` | `'Cancel'`, `'Upload anyway'` |
| Processing | `'Cancel processing?'` | `'Keep'`, `'Cancel job'` |
| Results / Live | `'<side> retires?'` | `'Cancel'`, `'Retire'` |
| Live | `'Stop and save this session?'` | `'Keep going'`, `'Stop and save'` |
| Live | `'Practice goal · <player>'` | `'Cancel'`, `'Save goal'` |
| Chat / Coach | source title | `'Open reference'`, `'Close'` |
| History | `'Delete analysis?'` | `'Cancel'`, `'Delete'` |
| Settings | `'Turning on coach chat'`, `'Disclaimer'` | `'OK'` |

### Bottom sheets
Connect help; Results re-render overlays; Results hit details.

### Snackbars
Connect `'Connected: …'`; Processing `'Could not cancel: …'`, retry error; Results `'Preparing …'`, `'Saved …'`, `'Download failed: …'`, `'No rally to replay yet. Move to the rally first.'`, `'Could not save goal: …'`, change errors; Live controller notices (§7.1); History `'Could not delete: …'`, `'This job has no results on the server any more.'`; source `'Could not open reference.'`; Styleguide sample.

### Keyboard shortcuts
Results: Space, Left, Right. Live (referee): N, F, Z, Ctrl+Z, L, E, I, O. Text fields: Enter submits on Connect, top-bar search, Chat, Coach.

### Gestures
Corner canvas tap / drag / pinch / scroll-zoom with loupe (Calibration, Live calibrate, Watch); timeline long press; History swipe-to-delete and pull-to-refresh.

---

## 18. Findings for the redesign

- Controls reachable in one layout only: rail theme toggle (medium/expanded; compact has only Settings > Appearance); top-bar search **field** with query (medium/expanded; compact icon opens History without a query); Calibration checklist (expanded) and Skip position (header on expanded, under the button otherwise); Results stats row (non-compact and height >= 640); Results Coach/Minimap/Score tabs (compact and landscape phone only, side panel otherwise); Live keys hint (non-compact only).
- Hidden or easy-to-miss features: `/styleguide` has no link; the general Coach screen is only reachable from the History header icon; Results keyboard shortcuts (only advertised in tooltips); Live `E` (change ends) and `Ctrl+Z` are not in the keys hint; timeline long press; History swipe and pull-to-refresh; bell menu refetches on open; loupe while dragging corners; media_kit default video controls (fullscreen etc.) inside Results.
- Duplicated controls: "Change mode" exists as `ChangeModeButton` (Upload, Live) and as a separate plain TextButton in Watch; theme in rail and Settings; Notify toggle in Processing and Settings; search in top bar and History; Live Stop in header and "Stop and save" in the match-over card; Undo as button and Z key; Practice goal UI is editable in Live but only completable (no Edit) in Results.
- Inconsistencies to decide on (not to silently fix): Settings privacy text says Claude API and `SHUTTLESENSE_ANTHROPIC_API_KEY`, while chat privacy says Gemini (or Claude); Processing says `'Back to upload'` though `/` may show Live or Watch; Processing error states use a Material AppBar while every other page uses PageHeader; Coach screen uses AppBar + outlined field while Chat uses PageHeader + rounded bar; Watch status uses both `'Rendering...'` and `'Rendering…'`; Processing stage trailing shows raw status words (`done`, `running`).
- Behaviour I could not fully determine from app code: the exact media_kit default control set in Results (platform-dependent package UI); Decision history entry wording (`entry.detail` comes from the server); server error texts passed through verbatim (API `detail`, Watch `error` events).

---

## 19. Strings that tests look up

From `app/test` (`find.text`, `find.textContaining`, `find.byTooltip`, `find.bySemanticsLabel`, `find.widgetWithText`). Keep these exactly, or update the tests in the same change. Strings marked (fixture) come from test data, not app code, but the widget that renders them must still render plain text. Keys also used by tests: `decision-menu`, `ends-changed`, `auto-change-ends`, `live-keys`, `live-review-queue`, `match-over`, `corner-0`, `corner-1`, `start-games-Far player`, `best_of`, `first_server_id`, `stroke_model`, `court`, `camera-preview`, `minimap`, `scoreboard`, `status`.

### Shell / responsive / not found / misc
| String | Finder | Test file |
|---|---|---|
| `History`, `Settings`, `Switch to dark theme`, `Search analyses` | byTooltip | responsive_test.dart |
| `Search analyses` (TextField) | widgetWithText | responsive_test.dart |
| `Home`, `Start an analysis`, `Connect to server`, `Connection` | text | responsive_test.dart |
| `Server unreachable` | textContaining | screens_test.dart |
| `Could not load jobs`, `Retry`, `Dark`, `boom` (fixture) | text | screens_test.dart |
| `0.1.0`, `job1` (fixture) | textContaining | screens_test.dart |
| `Page not found`, `Go to Home` | text | not_found_test.dart |
| `/no/such/page` | textContaining | not_found_test.dart |
| `Styleguide`, `Dark`, `Upload clip` | text | styleguide_test.dart |

### Connect / Upload
| String | Finder | Test file |
|---|---|---|
| `Connect`, `Connect anyway`, `Different data format`, `This server needs an access token`, `Connected: ShuttleSense 0.2.0 on CUDA`, `https://abc.trycloudflare.com` (fixture) | text | connect_upload_test.dart |
| `does not look like an address` | textContaining | connect_upload_test.dart |
| `Choose video`, `Calibrate court`, `Game already under way`, `Upload and analyze`, `Uploading 5.0 MB of 10.0 MB (50%)`, `Cancel`, `Cancelled`, `Long video`, `Upload anyway`, `The upload failed. Try again.`, `1:05 · 10.0 MB`, `rally.mp4` (fixture), `Video is longer than 10 minutes` (fixture) | text | connect_upload_test.dart |
| `Could not read the size`, `longer than the 10-minute server limit` | textContaining | connect_upload_test.dart |
| FilterChip `Player boxes`, `Skeletons` | widgetWithText | connect_upload_test.dart |
| `Advanced`, `Stroke model`, `Random Forest`, `Not installed on this server: LSTM.`, `Strokes named by the LSTM model` | text | stroke_model_test.dart |
| `No stroke model is installed`, `Strokes named by` | textContaining | stroke_model_test.dart |
| `Near player`, `Near player 1`, `Far player 2`, `Near pair`, `Far pair`, `Serves first`, `Singles`, `Far` | text | doubles_setup_test.dart |
| `The score moves with the players`, `Use Players changed ends` | textContaining | doubles_setup_test.dart |

### Home / Mode / History
| String | Finder | Test file |
|---|---|---|
| `Recent analyses`, `Upload your first rally`, `rally01.mp4` (fixture) | text | home_test.dart |
| `Upload clip`, `Last used` | text | coach_test.dart |
| `Delete` | byTooltip | history_test.dart |
| `Delete analysis?`, `Also delete the uploaded video`, `Cancel`, `Done`, `Live`, `No analyses match.`, `No analyses on this server yet`, `Start an analysis`, `This job has no results on the server any more.`, `rally01.mp4` (fixture) | text | history_test.dart |
| `Could not delete`, `Live ·`, `Upload ·` | textContaining | history_test.dart |
| FilledButton `Delete` | widgetWithText | history_test.dart |
| `Ask the coach` | byTooltip | coach_rag_test.dart |

### Calibration / Processing
| String | Finder | Test file |
|---|---|---|
| `Undo`, `Reset` | byTooltip | calibration_test.dart |
| `Skip`, `Start processing` | text | calibration_test.dart |
| `Near left`, `The corners cross over` | textContaining | calibration_test.dart |
| `Cancel`, `Cancel processing?`, `Keep`, `Cancel job`, `Lost connection to server`, `Running: Players and pose`, `Try again`, `View results`, `chat` (route fragment) | text | processing_test.dart |
| `Elapsed`, `Waiting in queue` | textContaining | processing_test.dart |

### Watch
| String | Finder | Test file |
|---|---|---|
| `Watch & Analyze`, `Choose video`, `Real time`, `Analyze every frame`, `Suggest automatically`, `Singles`, `Doubles`, `Find corners automatically`, `Clear corners`, `Suggest match format`, `Start analysis`, `Play`, `Pause`, `Stop and save` | text | watch_test.dart |
| `Playback waits for every normalized frame`, `Check the suggested outer court corners`, `Could not find the court reliably`, `Suggested: doubles` | textContaining | watch_test.dart |
| ChoiceChip `Singles`; FilledButton `Start analysis`; OutlinedButton `Find corners automatically`, `Suggest match format`; SwitchListTile `Faster player analysis (experimental)` | widgetWithText | watch_test.dart |

### Live
| String | Finder | Test file |
|---|---|---|
| `Change mode`, `Calibrate court`, `Start without court`, `Go live`, `Stop`, `Cancel`, `Try again`, `Open History`, `Open results`, `New session`, `Stop and save this session?`, `Keep going`, `Referee`, `Coach`, `Score and stats`, `IN PLAY`, `IN`, `UNCERTAIN`, `Confirm IN`, `Confirm OUT`, `Undo`, `Point Far`, `Players changed ends`, `Near serves · right court`, `Game 1 of 3 · games 0–0`, `Game already under way`, `Stroke model`, `Random Forest`, `Latency 42 ms`, `Reduced quality`, `Smash by Near · 212 km/h (est.)`, `1 call awaiting review`, `2 calls awaiting review`, `Reconnecting and refreshing the score…`, `Wait until the rally has ended, then award the point`, `The match is already won: Undo first to change the result`, `Next rally`, `Notes appear here after each rally.`, `Waiting for enough footage to suggest a cue for Far.`, `Pin cue`, `Clear pin`, `Pinned practice cue · Rally 3`, `Recent completed rallies`, `0`, `7` | text | live_test.dart |
| Fixture cue/note texts rendered by the coach panel: `1. Near player: Bent hitting arm at contact on 2 of 3 smashes`, `1. Near player 1: Low contact point`, `1. Far player 1: Slow recovery`, `2. Near player 2: Bent hitting arm`, `Near, Smash: Extend your hitting arm fully at contact.`, `Near 2, Smash: Extend your hitting arm fully at contact.`, `Far 1, Clear: Recover to base sooner.`, `Near, Smash: Earlier cue for near`, `Far, Smash: Earlier cue for far`, `heads up`, `no such line call` | text | live_test.dart |
| `Camera access was denied`, `Camera orientation changed`, `Camera stopped`, `Recalibrate the court`, `Cannot reach the live server`, `The live server closed the connection`, `closed the connection`, `The server is busy`, `did not confirm the save`, `Session saved to History`, `saved to History in about a minute`, `the decision was not sent`, `Waiting for a fresh analysis overlay`, `Near left corner`, `analysed 12`, `Rally 1 · 5 strokes · 6.2 s`, `not official calls`, `182 km/h (est.)`, `241 km/h (est.)`, `Bent hitting arm`, `Slow recovery`, `side by side` | textContaining | live_test.dart |
| ChoiceChip `Near`, `Far`; FilledButton `Stop and save` | widgetWithText | live_test.dart |
| `Coach`, `Next rally`, `Point Near`, `Start`, `Start without court`, `Set practice goal`, `Saving the practice goal…`, `Confirming the referee decision…`, `Interval · 60 s`, `Interval · 40 s`, `Interval · 35 s`, `Interval · 1 s`, `Interval complete`, `Decision history (1)`, `Decision history (2)`, `All games`, `Game 2`, `Undone only`, `1 of 2 decisions`, `No matching decisions`, `Award at frame 30` (fixture), `Award at frame 10 · Undone` (fixture) | text | courtside_depth_test.dart |
| FilledButton `Stop` | widgetWithText | courtside_depth_test.dart |
| `Decision history (1)` | text | courtside_preview.dart |

### Results (scoreboard, timeline, minimap, downloads, doubles)
| String | Finder | Test file |
|---|---|---|
| `Enable the referee layer to keep score.`, `Undo`, `Point Far`, `Players changed ends`, `Match won by Far`, `Match point Near`, `Game point Near`, `Near serves · left court`, `Interval: change ends`, `Game 2 of 3 · games 0–1`, `Game 3 of 3 · games 1–1`, `G1 21–17`, `G1 17–21`, `1 point(s) awarded` | text | scoreboard_test.dart |
| `Rally 1 · 3 strokes · in`, `in ?`, `correction(s)`, `1 point(s) awarded`, `1 change(s) of ends` | textContaining | scoreboard_test.dart |
| ChoiceChip `Near`, `Far` | widgetWithText | scoreboard_test.dart |
| `Undecided: pick the winner` | byTooltip | courtside_test.dart |
| `Far retires?`, `Cancel`, `Far wins (retired)`, `Game 1 of 3 · games 0–0`, `Game 2 of 3 · games 1–0`, `G1 21–17`, `G2 21–19`, `Interval (120 s): change ends`, `Games already won (starts in game 2 of 3)`, `0`, menu item labels via a variable (`text(item)`) | text | courtside_test.dart |
| Chip `Let`; FilledButton `Retire` | widgetWithText | courtside_test.dart |
| `Filter by stroke` | byTooltip | timeline_test.dart |
| `All strokes`, `Smash`, `Serve`, `Drop ?`, `Far`, `Clear`, `Form feedback`, `Heuristic guidance, not professional coaching.`, `Elbow extension` (fixture), `Contact above head` (fixture) | text | timeline_test.dart |
| `86% · ~241 km/h (est.)`, `Straighten your hitting arm` (fixture), `Keep both feet still` (fixture) | textContaining | timeline_test.dart |
| `Heatmap`, `Minimap`, `Annotated video not available` | text | minimap_test.dart |
| RegExp `Heatmap: `, `Shuttle at 3.0 m across, 8.0 m up`, `near player mostly at 2.6 m across` | bySemanticsLabel | minimap_test.dart |
| `Play (Space)`, `Pause (Space)` | byTooltip | downloads_test.dart |
| `0.5×`, `Strokes by player`, `Other` (test-only button) | text | downloads_test.dart |
| `Near: 2 hits, peak 241 km/h` | textContaining | downloads_test.dart |
| `N1`, `N2`, `F1`, `Near 1`, `Far 2`, `Near 1 serves to Far 2`, `Who serves first in game 2?`, `Set service` | text | doubles_view_test.dart |
| `Near: `, `Near 2: 1 hits`, `Far 2: 0 hits`, `Who serves first` | textContaining | doubles_view_test.dart |
| RegExp `^Near 2 player, Smash` (timeline row semantics) | bySemanticsLabel | doubles_view_test.dart |

### Coach panel, Chat, general Coach
| String | Finder | Test file |
|---|---|---|
| `Coach`, `Top things to fix`, `Ask your coach`, `Coach chat is off on this server`, `Question limit for this session reached`, `What should I fix first?`, `IN`, `UNCERTAIN`, `Confirm OUT`, `Call IN`, `Call OUT`, `Completed · self-reported`, `0:01.5`, `1 of 2`, kChatPrivacy, kCoachingDisclaimer; fixtures `Your elbow was bent on the smash [t=1.5s].`, `Your elbow `, `The coach is busy (rate limited).`, `coach chat is off`, `Shared finding`, `Shared practice goal`, `First partner cue`, `Second partner cue`, `Second partner goal`, `Opposing partner cue` | text | coach_test.dart |
| `no Gemini or Claude API key`, `The coach could not answer`, `cut off`, `official`, `Automated call · 30% confidence`, `3 cm outside the line`, `Confirmed by referee`, `Feet moving during the serve` (fixture) | textContaining | coach_test.dart |
| ChoiceChip `Near`, `Near 2` | widgetWithText | coach_test.dart |
| `Write the report again`, `Ask the coach` | byTooltip | coach_rag_test.dart |
| `Coaching report`, `Strengths`, `The coach is off on this server`, `What should I fix first?`, `When should I split step?`, `0:01.5`, kCoachPrivacy; fixtures `Split step`, `Straighter arm on smashes`, `Throw and reach for a straight arm`, `Bent hitting arm at contact`, `Contact point for overheads`, `Reach up to contact the shuttle.`, `3 hits in 1 rally. Top fix: bent hitting arm.`, `Land the split step as they hit [kb:footwork#split-step].`, `The coach is busy (Gemini rate limit).` | text | coach_rag_test.dart |
| `no AI provider answered` | textContaining | coach_rag_test.dart |
| TextField `Smash tips?` (typed text) | widgetWithText | coach_rag_test.dart |
