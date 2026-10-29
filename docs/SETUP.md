# Setup guide

How to get the backend and the app running on each machine. This page also replaces per-folder READMEs: data, weights and sample-clip instructions are all here.

- [1. Prerequisites](#1-prerequisites)
- [2. Clone](#2-clone)
- [3. Backend on a laptop (primary)](#3-backend-on-a-laptop-primary)
- [4. Backend on Google Colab (fallback)](#4-backend-on-google-colab-fallback)
- [5. Weights](#5-weights)
- [6. Datasets](#6-datasets)
- [7. App](#7-app)
- [8. Connecting a phone or tablet to the laptop](#8-connecting-a-phone-or-tablet-to-the-laptop)
- [9. Troubleshooting](#9-troubleshooting)

## 1. Prerequisites

| Tool | Needed for | Install |
| --- | --- | --- |
| Git | everything | <https://git-scm.com> |
| Python 3.11–3.13 | backend | <https://www.python.org/downloads/> (tick "Add to PATH") |
| NVIDIA driver + CUDA-capable GPU | fast backend | Latest Game Ready/Studio driver; PyTorch wheels bundle CUDA |
| ffmpeg | H.264 export | Windows: `winget install Gyan.FFmpeg`; macOS: `brew install ffmpeg`; Colab: preinstalled |
| Flutter 3.41 stable | app | <https://docs.flutter.dev/get-started/install>, then `flutter doctor` |
| Android Studio + SDK | Android builds | From the Flutter install guide; enable USB debugging on the phone |
| Visual Studio 2022, "Desktop development with C++" | Windows builds | Visual Studio Installer |
| Xcode (macOS only) | iOS/iPadOS builds | App Store |
| Chrome or Edge | web builds | — |

## 2. Clone

```bash
git clone --recurse-submodules https://github.com/Mist10148/ShuttleSense.git
cd ShuttleSense
# Already cloned without submodules?
git submodule update --init --recursive
```

## 3. Backend on a laptop (primary)

```bash
cd backend
python -m venv .venv
# Windows (PowerShell):  .venv\Scripts\Activate.ps1
# Windows (Git Bash):    source .venv/Scripts/activate
# macOS / Linux:         source .venv/bin/activate

pip install -r requirements/base.txt -r requirements/dev.txt
pip install -e .
```

That is enough to run the API with the stub pipeline, the tests and the lint. For the real models also install the ML stack. Install the CUDA build of PyTorch first, using the exact command from the selector at <https://pytorch.org/get-started/locally/> (Stable, your OS, Pip, Python, latest CUDA), with the version from `requirements/ml.txt`:

```bash
pip install torch==2.15.0 torchvision --index-url https://download.pytorch.org/whl/<cuda-tag>
pip install -r requirements/ml.txt
python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

Run the server so other devices on the network can reach it:

```bash
uvicorn shuttlesense.api.main:app --host 0.0.0.0 --port 8000
# open http://localhost:8000/docs to try the endpoints
```

Run the pipeline from the command line instead of the API:

```bash
python -m shuttlesense.run --video ../samples/rally01.mp4 --out outputs/rally01
```

Check your work before pushing:

```bash
ruff check . && ruff format --check . && pytest
```

### Backend environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `SHUTTLESENSE_STORAGE_DIR` | `storage` (inside `backend/`) | Uploads and job outputs |
| `SHUTTLESENSE_TOKEN` | unset | Require `Authorization: Bearer <token>`; set it whenever the server is exposed through a tunnel |
| `SHUTTLESENSE_DEVICE` | auto | `cuda` or `cpu` |
| `SHUTTLESENSE_CORS_ORIGINS` | `*` | Comma-separated origins for the web build |
| `SHUTTLESENSE_MAX_UPLOAD_MB` | `1024` | Upload size limit |
| `SHUTTLESENSE_CONFIG` | `configs/pipeline.yaml` | Pipeline config file |

## 4. Backend on Google Colab (fallback)

1. Open [`backend/notebooks/shuttlesense_colab.ipynb`](../backend/notebooks/shuttlesense_colab.ipynb) in Colab (File > Open notebook > GitHub).
2. Runtime > Change runtime type > **T4 GPU**.
3. Set a token in the first cell (`SHUTTLESENSE_TOKEN = "..."`), then Run all.
4. The last cell prints a `https://<random>.trycloudflare.com` URL. Enter it and the token in the app's connect screen.

The session (and its uploads) disappears when Colab disconnects. Download results before closing the tab.

## 5. Weights

Weights are not committed (`backend/weights/` is gitignored).

```bash
cd backend
python scripts/download_weights.py            # all weights
python scripts/download_weights.py --only tracknet
```

Expected layout after download:

```
backend/weights/
├── tracknet/TrackNet_best.pt
├── tracknet/InpaintNet_best.pt
└── strokes/stroke_cnn.pt        # after Phase 3 training
```

RTMDet/RTMPose ONNX files are downloaded and cached by rtmlib on first use.

## 6. Datasets

Datasets are not committed (`backend/data/` is gitignored) and match videos are never redistributed. Follow ShuttleSet's terms of use.

```bash
cd backend
python scripts/download_shuttleset.py                 # annotations + match list -> data/shuttleset/
python scripts/extract_clips.py --matches 1-22        # Member 3
python scripts/extract_clips.py --matches 23-44       # Member 4
python scripts/extract_features.py                    # -> data/features/*.npz, data/splits.json
python scripts/train_stroke_classifier.py --config configs/stroke_cnn.yaml
```

Processed `clips/` and `features/` are shared through the team Google Drive folder so not everyone re-runs extraction. Layout is described in [DATA_FORMAT.md](DATA_FORMAT.md#training-data-layout-stroke-classifier).

**Sample clips** for the demo go in `samples/` (gitignored). Only add clips of people who agreed to be recorded.

## 7. App

```bash
cd app
flutter pub get
flutter analyze && flutter test
```

Run on each target:

| Target | Command |
| --- | --- |
| Chrome (web) | `flutter run -d chrome` |
| Windows | `flutter run -d windows` |
| Android phone/tablet (USB or wireless debugging) | `flutter devices` then `flutter run -d <id>` |
| Android emulator | `flutter emulators --launch <name>` then `flutter run` |
| iPhone / iPad (Mac only) | `cd ios && pod install && cd ..` then `flutter run -d <id>` |

Pre-fill the server URL in a build (optional):

```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://192.168.1.20:8000
```

Release builds (Phase 7):

```bash
flutter build apk --release                 # build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release             # build/windows/x64/runner/Release/
flutter build web --release                 # build/web/
flutter build ipa                           # Mac only
```

To test layouts, resize the Windows/Chrome window or use Chrome DevTools device mode: under 600 px wide is the phone layout, 600–1023 px the tablet layout, 1024 px and up the laptop layout.

## 8. Connecting a phone or tablet to the laptop

1. Put the laptop and the phone/tablet on the **same Wi-Fi** (campus networks often isolate clients; a phone hotspot works).
2. Find the laptop's IP: `ipconfig` (Windows, "IPv4 Address") or `ip addr` (Linux/macOS).
3. Allow port 8000 through the Windows firewall once (PowerShell as Administrator):

   ```powershell
   New-NetFirewallRule -DisplayName "ShuttleSense API" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private
   ```

4. Start the backend with `--host 0.0.0.0`.
5. In the app's connect screen enter `http://<laptop-ip>:8000` and tap **Connect**.

## 9. Troubleshooting

| Symptom | Fix |
| --- | --- |
| App says "Cannot reach server" from a phone but `localhost:8000/docs` works on the laptop | Firewall rule (step 8.3), wrong IP, different Wi-Fi, or client isolation; try a hotspot |
| Web build cannot call the backend | Check `SHUTTLESENSE_CORS_ORIGINS`; an `https://` page cannot call an `http://` server, so use the tunnel URL or serve the web build over `http://` |
| `torch.cuda.is_available()` is `False` | Install the CUDA wheel from the PyTorch index (section 3), update the NVIDIA driver |
| Annotated video does not play in the app | Make sure ffmpeg is installed so the export is H.264 (`ffmpeg -version`) |
| `flutter build windows` fails | Install Visual Studio 2022 "Desktop development with C++"; run `flutter doctor` |
| Colab URL stopped working | The Colab session ended; re-run the notebook and enter the new URL |
