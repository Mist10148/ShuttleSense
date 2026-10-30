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

## Schema v1.1

v1.1 (Oct 31, [D19](DECISIONS.md)) adds optional fields only: `mode`, `feedback[].value`, `line_calls`, `rally_events`, `coaching` and `chat`. `schema.migrate()` upgrades a 1.0 `record.json` when it is read (API, scripts, fake pipeline), so old jobs keep working and gain line calls derived from their rallies. The app accepts any `1.x`.

```jsonc
{
  "schema_version": "1.1",
  "clip_id": "match03_rally12",          // unique per processed clip
  "mode": "upload",                       // v1.1: "upload" | "live" (a saved live session)
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
        {"rule": "contact_above_head", "passed": true,  "tip": null, "value": 0.12},
        {"rule": "elbow_extension",    "passed": false, "tip": "Extend your hitting arm fully at contact.", "value": 131.0}  // v1.1: measured quantity
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
    "stroke_counts": {"smash": 2, "clear": 2, "drop": 1, "net_shot": 1, "lift": 1},  // classes with no hit are left out
    "peak_speed_kmh": 182.0,
    "per_player": {
      "near": {"hits": 4, "stroke_counts": {"smash": 2, "clear": 1, "drop": 1}, "peak_speed_kmh": 182.0},
      "far":  {"hits": 3, "stroke_counts": {"clear": 1, "net_shot": 1, "lift": 1}, "peak_speed_kmh": 95.0}
    }
  },

  "line_calls": [                                              // v1.1, F20; empty without referee or court
    {
      "id": 0,
      "rally_index": 0,
      "frame": 400, "time_s": 13.333,                         // landing frame, tap-to-seek
      "call": "in",                                           // "in" | "out": automated, never official
      "landing_xy": [4.9, 12.1],                               // court meters
      "margin_cm": 28.0,                                       // signed distance to the nearest relevant line, + inside
      "confidence": 0.72,
      "uncertain": false,                                      // |margin| inside the uncertainty band
      "court": "singles",                                      // "singles" | "doubles" lines
      "override": null                                         // {"call": "out", "at": "...Z"} after the user confirms or overrides
    }
  ],

  "rally_events": [                                            // v1.1: what live mode streamed, in order
    {"frame": 12,  "time_s": 0.4,    "type": "rally_start", "rally_index": 0, "data": {}},
    {"frame": 42,  "time_s": 1.4,    "type": "hit",         "rally_index": 0, "data": {"hit_id": 0}},
    {"frame": 400, "time_s": 13.333, "type": "landing",     "rally_index": 0, "data": {"line_call_id": 0}},
    {"frame": 410, "time_s": 13.667, "type": "rally_end",   "rally_index": 0, "data": {}},
    {"frame": 410, "time_s": 13.667, "type": "score",       "rally_index": 0, "data": {"near": 11, "far": 9}}
  ],

  "coaching": {                                                // v1.1, F21; null before the feedback stage
    "session_notes": [
      {"id": "elbow_extension:smash", "rule": "elbow_extension", "stroke": "smash",
       "text": "Bent elbow at contact on 3 of 5 smashes", "count": 3, "total": 5, "severity": 1.0,
       "moments": [{"frame": 42, "time_s": 1.4, "hit_id": 0}]}
    ],
    "top_fixes": ["elbow_extension:smash"]                    // note ids, most important first, at most 3
  },

  "chat": {                                                    // v1.1, F22; null until the first question
    "messages": [
      {"role": "user", "text": "Why did my smashes land short?", "at": "2026-11-17T10:30:00Z", "citations": []},
      {"role": "assistant", "text": "Your elbow was bent at contact on 3 of 5 smashes [t=1.4s]...",
       "at": "2026-11-17T10:30:04Z", "citations": [{"frame": 42, "time_s": 1.4, "hit_id": 0}]}
    ]
  }
}
```

Every `frame` / `time_s` pair (hits, line calls, rally events, note moments, chat citations) is a seek target: the app seeks to `time_s` minus a short lead.

### Stroke classes

The six output classes use these exact identifiers: `smash`, `clear`, `drop`, `net_shot`, `lift`, `serve`.

Mapping from ShuttleSet's 18 annotated types plus "unknown" (task T3.3; `strokes/labels.py` holds the same table). The annotation CSVs name types in Chinese; the English names follow the ShuttleSet paper:

| ShuttleSet type (CSV) | English name | ShuttleSense class |
| --- | --- | --- |
| 殺球, 點扣 | smash, wrist smash | `smash` |
| 長球 | clear | `clear` |
| 切球, 過度切球 | drop, passive drop | `drop` |
| 放小球, 擋小球, 勾球, 撲球 | net shot, return net, cross-court net shot, rush | `net_shot` |
| 挑球, 防守回挑, 推球 | lob, defensive return lob, push | `lift` |
| 發短球, 發長球 | short service, long service | `serve` |
| 平球, 小平球, 後場抽平球, 防守回抽 | drive, driven flight, back-court drive, defensive return drive | excluded from training (no matching class); report count |
| 未知球種 | unknown | excluded |

## Derived exports

| File | Content | Producer |
| --- | --- | --- |
| `record.json` | The full clip record above | pipeline |
| `summary.json` | `{clip_id, fps, summary, score, rallies, rally_stats}` subset | analytics (F13) |
| `hits.csv` | One row per hit: `id,frame,time_s,player,stroke,confidence,speed_kmh,tip,rally_index` (UTF-8 with BOM) | analytics (F13) |
| `rallies.csv` | One row per rally: `index,start_frame,end_frame,start_s,end_s,stroke_count,peak_speed_kmh,winner,landing_in,landing_confidence,score_near,score_far` (UTF-8 with BOM) | analytics (F13) |
| `annotated.mp4` | H.264, yuv420p, same fps and size as the normalized clip | render (F7) |
| `tracking.csv` | `frame,visible,x,y,source` (TrackNetV3 format plus `source`: `net`, `interp` or empty) for debugging and evaluation | tracking (F2) |

## Training data layout (stroke classifier)

Produced by `scripts/extract_clips.py` and `scripts/extract_features.py` under `backend/data/` (gitignored, shared via Google Drive):

```
backend/data/
├── shuttleset/                 # raw annotations from the ShuttleSet repo
├── videos/                     # match videos (not redistributed)
├── clips/<match_id>/<set>_<rally>_<stroke>.mp4 + index.csv
├── features/<match_id>.npz     # X: [N, T, F] pose+shuttle windows, y: [N], meta
└── splits.json                 # {"train": [match_ids], "val": [...], "test": [...]} — split by match
```

Feature window per hit: `T = 32` frames centered on the hit frame (`extract_features.py --window`; the checkpoint stores `window_frames` and inference uses it). Per frame `F` = hitter's 17 keypoints × (x, y) normalized to the player's bbox, plus shuttle (x, y, visible, dx, dy) normalized to the frame. The pose-only ablation drops the shuttle features.
