# Data format: the clip record

Every pipeline stage reads and writes one JSON document per processed clip, the **clip record**. The app reads the same document to draw the minimap, status bar, timeline and scoreboard. This page is the human-readable spec; the executable source of truth is [`backend/shuttlesense/schema.py`](../backend/shuttlesense/schema.py) and the Dart mirror is [`app/lib/data/models/`](../app/lib/data/models/).

**Change policy.** The schema is frozen at the end of Phase 1 (task T1.1). After that, any change needs the lead's approval, a bump of `schema_version`, and matching updates to `schema.py`, the Dart models, this page and the tests in the same PR. Adding an optional field is a minor bump (`1.1`); renaming or removing a field is a major bump (`2.0`).

## Conventions

| Topic | Convention |
| --- | --- |
| Pixel coordinates | Origin top-left of the **normalized** video frame (after io resizing), x right, y down, floats |
| Court coordinates | Meters on the court plane. Origin at the near-left corner of the singles court, x across the court (0 to 5.18), y toward the far baseline (0 to 13.40) |
| Frame index | 0-based index into the normalized video; time in seconds is `frame / fps`. `frames[]` holds **every** normalized frame (after fps downsampling), in order |
| Players | Always `"near"` (closer to the camera, bottom of the image) or `"far"` |
| Missing values | `null`, never `-1` or `0`, except `shuttle.visible` which is `0` or `1` as in TrackNetV3 |
| Confidences | Floats in [0, 1]. A keypoint with `score < 0.3` counts as missing: stages that read joints (hits, feedback, positions) ignore it |
| Speeds | km/h, always estimates |

### Court corners order

`court.corners_px` lists the four **singles** court corners in this order (the app's calibration screen asks for them in the same order):

```
3 far-left  ┌──────────┐ 2 far-right
            │          │
            │   net    │
            │──────────│
            │          │
0 near-left └──────────┘ 1 near-right      (camera side)
```

### Keypoints

`keypoints` use the 17-point COCO layout, each `[x, y, score]` in pixels:

| Index | Joint | Index | Joint |
| --- | --- | --- | --- |
| 0 | nose | 9 | left wrist |
| 1 | left eye | 10 | right wrist |
| 2 | right eye | 11 | left hip |
| 3 | left ear | 12 | right hip |
| 4 | right ear | 13 | left knee |
| 5 | left shoulder | 14 | right knee |
| 6 | right shoulder | 15 | left ankle |
| 7 | left elbow | 16 | right ankle |
| 8 | right elbow | | |

## Schema v1.0

```jsonc
{
  "schema_version": "1.0",
  "clip_id": "match03_rally12",          // unique per processed clip
  "source_name": "rally12.mp4",          // original file name, informational
  "fps": 30.0,
  "width": 1280,
  "height": 720,
  "num_frames": 900,

  // null until court calibration runs (P2)
  "court": {
    "corners_px": [[212.0, 650.0], [1068.0, 650.0], [880.0, 210.0], [400.0, 210.0]],
    "homography": [[0.01, 0.0, -2.1], [0.0, 0.03, -6.4], [0.0, 0.0, 1.0]],  // image px -> court m
    "court_size_m": [5.18, 13.40]
  },

  "frames": [
    {
      "frame": 0,
      "shuttle": {"x": 512.0, "y": 288.0, "visible": 1},        // F2; null if tracking disabled
      "players": {                                             // F3/F4; a side is null if not detected
        "near": {"bbox": [480.0, 400.0, 120.0, 300.0], "score": 0.94,
                 "keypoints": [[540.0, 420.0, 0.91], "... 17 total"]},
        "far":  {"bbox": [600.0, 180.0, 60.0, 150.0], "score": 0.88,
                 "keypoints": [[628.0, 190.0, 0.85], "... 17 total"]}
      },
      "court_positions": {                                     // F10; null without calibration
        "near": [2.6, 1.9], "far": [2.4, 11.8], "shuttle": null
      },
      "shuttle_speed_kmh": null,                               // F11
      "rally_state": null                                      // F14: "in_play" | "between_rallies"
    }
  ],

  "hits": [
    {
      "id": 0,
      "frame": 42,
      "time_s": 1.4,
      "player": "near",                                        // F5
      "stroke": "smash",                                       // F6: one of the 6 classes, null until classified
      "confidence": 0.81,
      "class_probs": {"smash": 0.81, "clear": 0.09, "drop": 0.05, "net_shot": 0.02, "lift": 0.02, "serve": 0.01},
      "speed_kmh": 182.0,                                      // F11, estimated
      "feedback": [                                            // F8
        {"rule": "contact_above_head", "passed": true,  "tip": null},
        {"rule": "elbow_extension",    "passed": false, "tip": "Extend your hitting arm fully at contact."}
      ],
      "rally_index": 0                                         // F14, null if rallies not detected
    }
  ],

  "rallies": [                                                 // F14–F16; empty list if referee disabled
    {
      "index": 0,
      "start_frame": 12,
      "end_frame": 410,
      "stroke_count": 7,
      "landing": {"x_m": 4.9, "y_m": 12.1, "in_court": true, "confidence": 0.72},
      "winner": "near",
      "score_after": {"near": 11, "far": 9}
    }
  ],

  "score": {                                                   // F16; null if referee disabled
    "near": 11,
    "far": 9,
    "corrections": [
      {"rally_index": 0, "winner_before": "far", "winner_after": "near", "at": "2026-11-17T10:22:00Z"}
    ]
  },

  "summary": {                                                 // F13
    "total_hits": 7,
    "stroke_counts": {"smash": 2, "clear": 2, "drop": 1, "net_shot": 1, "lift": 1, "serve": 0},
    "peak_speed_kmh": 182.0,
    "per_player": {
      "near": {"hits": 4, "stroke_counts": {"smash": 2, "clear": 1, "drop": 1}, "peak_speed_kmh": 182.0},
      "far":  {"hits": 3, "stroke_counts": {"clear": 1, "net_shot": 1, "lift": 1}, "peak_speed_kmh": 95.0}
    }
  }
}
```

### Stroke classes

The six output classes use these exact identifiers: `smash`, `clear`, `drop`, `net_shot`, `lift`, `serve`.

Draft mapping from ShuttleSet's 18 annotated types (finalized by Member 4 in task T3.3; record the final table here):

| ShuttleSet type | ShuttleSense class |
| --- | --- |
| smash, wrist smash | `smash` |
| clear | `clear` |
| drop, passive drop | `drop` |
| net shot, return net, cross-court net shot, rush | `net_shot` |
| lob, defensive return lob, push | `lift` |
| short service, long service | `serve` |
| drive, driven flight, back-court drive, defensive return drive | excluded from training (no matching class); report count |

## Derived exports

| File | Content | Producer |
| --- | --- | --- |
| `record.json` | The full clip record above | pipeline |
| `summary.json` | `{clip_id, fps, summary, score, rallies}` subset | analytics (F13) |
| `hits.csv` | One row per hit: `id,frame,time_s,player,stroke,confidence,speed_kmh,tip,rally_index` | analytics (F13) |
| `annotated.mp4` | H.264, yuv420p, same fps and size as the normalized clip | render (F7) |
| `tracking.csv` | `frame,visible,x,y` (TrackNetV3 format) for debugging and evaluation | tracking (F2) |

## Training data layout (stroke classifier)

Produced by `scripts/extract_clips.py` and `scripts/extract_features.py` under `backend/data/` (gitignored, shared via Google Drive):

```
backend/data/
├── shuttleset/                 # raw annotations from the ShuttleSet repo
├── videos/                     # match videos (not redistributed)
├── clips/<match_id>/<rally>_<hit>.mp4
├── features/<match_id>.npz     # X: [N, T, F] pose+shuttle windows, y: [N], meta
└── splits.json                 # {"train": [match_ids], "val": [...], "test": [...]} — split by match
```

Feature window per hit: `T = 32` frames centered on the hit frame (configurable in `configs/stroke_cnn.yaml`). Per frame `F` = hitter's 17 keypoints × (x, y) normalized to the player's bbox, plus shuttle (x, y, visible, dx, dy) normalized to the frame. The pose-only ablation drops the shuttle features.
