# Release checklist

How to cut a ShuttleSense release (tasks T7.6 and T7.7). Follow it top to bottom. Each step ends with something you can check before going on.

## 1. Freeze

- [ ] Every task due before the freeze is ✅ in [docs/phases/](phases/), or has been formally cut and recorded in the PRD's Future work.
- [ ] `main` is green: the backend and app workflows both passed on the last commit.
- [ ] No open PR touches `schema.py`, `api/` or `app/lib/data/`.

## 2. Bump the version

The version appears in three places. They must match (`X.Y.Z`, for example `1.0.0`):

| File | Field |
| --- | --- |
| `backend/pyproject.toml` | `version = "X.Y.Z"` |
| `backend/shuttlesense/__init__.py` | `__version__ = "X.Y.Z"` (shown by `GET /health`) |
| `app/pubspec.yaml` | `version: X.Y.Z+N`, where `N` is the Android version code and must go up on every release |

If the clip record or API changed since the last release, also bump `SCHEMA_VERSION` in `schema.py` and `Health.expectedSchema` in `app/lib/data/models/health.dart`, then regenerate the snapshots:

```bash
cd backend && UPDATE_SNAPSHOTS=1 pytest
```

Commit the bump on its own: `chore: release vX.Y.Z`.

## 3. Pin weights

- [ ] `backend/scripts/download_weights.py` lists a SHA-256 in `CHECKSUMS` for every file in `FILES`.
- [ ] A fresh clone passes this check (it reports `fetched+verified` or `verified` for each file):

```bash
python scripts/download_weights.py --force
```

## 4. Build every artifact

Run the builds from `app/` on a clean checkout of the bumped commit.

| Target | Command | Output |
| --- | --- | --- |
| Android | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |
| Windows | `flutter build windows --release` | `build/windows/x64/runner/Release/` (zip the whole folder) |
| Web | `flutter build web --release` | `build/web/` (zip it) |
| iOS (if a Mac is available) | `flutter build ipa --release` | `build/ios/ipa/` |

**Android signing.** Create `app/android/key.properties`. It is gitignored, so never commit it. Keep the keystore in the team's private Drive.

```properties
storeFile=/absolute/path/to/shuttlesense.jks
storePassword=...
keyAlias=shuttlesense
keyPassword=...
```

Without this file, release builds are signed with the debug key. That is fine for team phones, but not for distributing the app.

## 5. Smoke test each artifact

Use the backend with the fake pipeline, so the test does not depend on a GPU:

```bash
cd backend
SHUTTLESENSE_FAKE_PIPELINE=1 uvicorn shuttlesense.api.main:app --host 0.0.0.0 --port 8000
```

For each artifact (Android phone, Windows, Chrome):

- [ ] Connect to the server.
- [ ] Upload a short clip and calibrate it.
- [ ] Check that the results show the annotated video, 3 timeline rows, minimap dots and the score.
- [ ] Download the CSV.
- [ ] Delete the job from History.

Then repeat once with the real pipeline (fake pipeline off) on the laptop GPU, using `samples/rally01.mp4`.

For live referee and coaching acceptance, also use a real camera and calibrated court:

- [ ] Compare portrait and landscape preview, calibration still and overlays for crop, rotation and mirroring.
- [ ] Record irregular capture and a reconnect; compare playback and rally/event times with elapsed time. This remains a known open issue.
- [ ] Award and undo a point, clear a winner, override an uncertain call, and verify the score and coaching summary after each decision and after reconnecting.
- [ ] Check the coaching panel at arm's length on a phone and tablet, and test chat with a configured API key.
- [ ] Run the model-backed live latency and labelled landing evaluations in [Phase 8](phases/phase-8-live-coach.md#t812); record hardware and measured results.

## 6. Tag and publish

```bash
git tag -a vX.Y.Z -m "ShuttleSense vX.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z --title "ShuttleSense vX.Y.Z" --notes-file release-notes.md \
  app-release.apk shuttlesense-windows.zip shuttlesense-web.zip
```

### Release notes template

```markdown
## ShuttleSense vX.Y.Z

### What's new
- …

### Results (see README Evaluation)
- Stroke accuracy (ShuttleSet test, 6 classes): …
- Hit detection F1: …
- Processing time, 1-minute 720p clip: …

### Downloads
- Android APK, Windows zip, web build zip. The backend runs from source (see docs/SETUP.md).

### Known limitations
- Speed and in/out calls are estimates; singles only; camera angle matters (README Limitations).
```

## 7. After the release

- [ ] Fill in README's Evaluation table and set the status badge to the release.
- [ ] Bring the docs in line with what actually shipped (T7.12), and add any late decisions to [DECISIONS.md](DECISIONS.md).
- [ ] Close the release milestone on GitHub.
