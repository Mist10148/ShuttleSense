# Data format: the clip record

Every pipeline stage reads and writes one JSON document per processed clip, the **clip record**. The app reads the same document to draw the minimap, status bar, timeline and scoreboard. This page is the human-readable spec; the executable source of truth is [`backend/shuttlesense/schema.py`](../backend/shuttlesense/schema.py) and the Dart mirror is [`app/lib/data/models/`](../app/lib/data/models/).

**Change policy.** The schema is frozen at the end of Phase 1 (task T1.1). After that, any change needs the lead's approval, a bump of `schema_version`, and matching updates to `schema.py`, the Dart models, this page and the tests in the same PR. Adding an optional field is a minor bump (`1.1`); renaming or removing a field is a major bump (`2.0`).

## Conventions

| Topic | Convention |
| --- | --- |
| Pixel coordinates | Origin top-left of the **normalized** video frame (after io resizing), x right, y down, floats |
| Court coordinates | Meters on the court plane. Origin at the near-left corner of the singles court, x across the court (0 to 5.18), y toward the far baseline (0 to 13.40) |
| Frame index | 0-based index into the normalized video; time in seconds is `frame / fps`. `frames[]` holds **every** normalized frame (after fps downsampling), in order |
| Players | A side is always `"near"` (closer to the camera, bottom of the image) or `"far"`: an end of the court, whoever stands there (v1.7: the score moves with the players when they change ends). In doubles (v1.2) each person also has a slot: `near_1`, `near_2`, `far_1`, `far_2`; `near_1`/`far_1` live in the `near`/`far` fields, partners in `near_2`/`far_2`. Slot 1 is the left one when play starts; the slot then stays with that person as the partners move |
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

## Schema v1.7 (player display and jump observations)

Two optional flags are omitted when true and default to true in older records.
`frames[].player_hold_safe` may be false in historical recordings when the former camera-view
guard could not verify the view; renderers must not carry a held box across that frame. The
current tracker assumes a fixed camera and does not use that guard. A player's `court_position_valid`
is false when a locked player is matched just beyond the court boundary; their pose is a
measurement, but their projected floor position is excluded from court analytics. Held
boxes themselves are display-only and are not stored as player measurements. The app's
record model reads the frame flag and does not consume player pose objects from records.

## Schema v1.5 (courtside referee)

v1.5 (Nov 14, [D33](DECISIONS.md), [T12.3](phases/phase-12-courtside.md#t123)) adds optional fields only, each left out of the JSON while it is `null`, so older records load unchanged:

| Where | Field | Meaning |
| --- | --- | --- |
| `score` | `start_games` | `{"near": 1, "far": 0}`: games each side had already won when the session started (joined mid-match). The game number follows from it; `score.games` lists only the games played in the session |
| `score` | `interval_s` | While `interval` is true: `60` (the leader reached 11) or `120` (between games, Laws 16.2). `interval` is now also true right after a game that does not end the match |
| `score.corrections[]` | `reason` | Why the referee decided it: `"let"` (a cleared rally to replay), `"fault"`, `"service_fault"` or `"misconduct"` |
| `score.corrections[]` | `kind: "concede"` | The other side retired or gave a walkover: `winner_after` wins the match there, and later rallies do not count. The score shows the game being played |

## Schema v1.4 (stroke model)

v1.4 (Nov 14, [D28](DECISIONS.md), [T11.7](phases/phase-11-stroke-models.md#t117)) adds one optional top-level field: `stroke_model`, the classifier that labelled `hits[].stroke` (`"cnn"`, `"lstm"` or `"rf"`), or `null` when no stroke model ran. `schema.migrate()` reads 1.0–1.3 records unchanged.

## Schema v1.3 (doubles service in every game)

v1.3 (Nov 14, [D23](DECISIONS.md), [T10.3](phases/phase-10-hardening.md#t103)) adds one optional field, left out while empty: `score.game_service`, a list of `{"game": 2, "server_id": "far_2", "receiver_id": "near_1"}`. The winners of a game choose who serves and receives first in the next one, so the user names them (`POST /jobs/{id}/score/service` or the live `service` message). With a game's entry, `rallies[].server_id` / `receiver_id` and the service check cover that game too. An entry whose server is not on the side that won the previous game is ignored. `schema.migrate()` reads 1.0–1.2 records unchanged.

## Schema v1.2 (doubles)

v1.2 (Nov 12, [D22](DECISIONS.md), [Phase 9](phases/phase-9-doubles.md)) adds optional doubles fields only. Each is **left out of the JSON while it is empty**, so a singles record looks exactly like v1.1 apart from `schema_version`. `schema.migrate()` reads 1.0 and 1.1 records; the app accepts any `1.x`.

| Where | Field | Meaning |
| --- | --- | --- |
| `frames[].players` | `near_2`, `far_2` | The partner on each side (same shape as `near` / `far`) |
| `frames[].court_positions` | `near_2`, `far_2` | Their court positions |
| `hits[]` | `hitter`, `hitter_confidence` | The slot who hit (`player` stays the side). Absent when the two partners were about as close to the shuttle |
| `rallies[]` | `server_id`, `receiver_id` | Who served and received the rally (the first game, and later games the user named in `score.game_service`, v1.3) |
| `rallies[]` | `review` | Why the user should check the rally: pose disagrees with the derived service order. Never changes the score |
| `score` | `first_server_id`, `first_receiver_id`, `server_id`, `receiver_id` | The user's first server and receiver, and who serves and receives next |
| `summary.per_player` | `near_1` … `far_2` keys | Per partner, next to the `near` / `far` side totals |
| `coaching.session_notes[]` | `player` | A slot for form and out notes in doubles, or the side when the partners were too close to tell who hit; `rule: "formation"` notes (severity 0) say how often each pair played front and back or side by side |

`line_calls[].court` is `"doubles"` for a doubles job; the doubles lines are the side alleys (0.46 m outside each singles sideline) and, for serves, the long service line 0.76 m inside the baseline. Court coordinates keep their origin at the singles corner, so alley points have `x < 0` or `x > 5.18`.

## Schema v1.1

v1.1 (Oct 31, [D19](DECISIONS.md)) adds optional fields only: `mode`, `feedback[].value`, `line_calls`, `rally_events`, `coaching` and `chat`. `schema.migrate()` upgrades a 1.0 `record.json` when it is read (API, scripts, fake pipeline), so old jobs keep working and gain line calls derived from their rallies. The app accepts any `1.x`.

```jsonc
{
  "schema_version": "1.5",
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
      "shuttle_speed_kmh": null,                               // F11, estimated
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
      "score_after": {"near": 11, "far": 9},                   // score of its game after it; null once the match is over
      "game": 1                                                // v1.1: game of the match (D21)
    }
  ],

  "score": {                                                   // F16; null if referee disabled
    "near": 11,
    "far": 9,
    "corrections": [
      {"rally_index": 0, "winner_before": "far", "winner_after": "near", "at": "2026-11-17T10:22:00Z",
       "kind": "winner", "frame": null},                     // winner_after null: rally undecided again
      {"rally_index": 1, "winner_before": null, "winner_after": "far", "at": "2026-11-17T10:23:00Z",
       "kind": "award", "frame": 640}                        // a point the system missed, counted before rally 1
    ],
    // Match state (v1.1 additions, D21), derived from the rally winners:
    "best_of": 1,                                            // 1 or 3
    "first_server": "near",                                  // set by the user, null if unknown
    "game": 1,                                               // current game (the last one once the match is over)
    "games": [],                                             // finished games: [{"near": 21, "far": 17}, ...]
    "games_won": {"near": 0, "far": 0},
    "server": "near",                                        // serves the next rally; null until known
    "service_court": "right",                                // right on the server's even score, else left
    "game_point": [],                                        // sides one point from the game
    "match_point": [],
    "match_winner": null,
    "interval": false,                                       // the leader reached 11, or a game just ended (interval_s 60 / 120, v1.5)
    "change_ends": false                                     // after a game, and at 11 in the deciding game or a one-game match
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
      "frame": 410, "time_s": 13.667,                         // landing frame = the rally's end_frame, tap-to-seek
      "call": "in",                                           // "in" | "out": automated, never official
      "landing_xy": [4.9, 12.1],                               // court meters
      "margin_cm": 28.0,                                       // signed distance to the nearest relevant line, + inside
      "confidence": 0.72,
      "uncertain": false,                                      // |margin| inside the uncertainty band
      "court": "singles",                                      // "singles" | "doubles" lines (and players, v1.2)
      "override": null                                         // {"call": "out", "at": "...Z"} after the user confirms or overrides
    }
  ],

  "rally_events": [                                            // v1.1: what live mode streamed, in order
    {"frame": 12,  "time_s": 0.4,    "type": "rally_start", "rally_index": 0, "data": {}},
    {"frame": 42,  "time_s": 1.4,    "type": "hit",         "rally_index": 0,
     "data": {"hit_id": 0, "player": "near", "stroke": "smash"}},   // doubles (v1.2): also "hitter" when known
    {"frame": 410, "time_s": 13.667, "type": "landing",     "rally_index": 0,
     "data": {"line_call_id": 0, "call": "in"}},                  // call after any override
    {"frame": 410, "time_s": 13.667, "type": "rally_end",   "rally_index": 0, "data": {"winner": "near"}},
    {"frame": 410, "time_s": 13.667, "type": "score",       "rally_index": 0, "data": {"near": 11, "far": 9}}
  ],

  "coaching": {                                                // v1.1, F21; null before the feedback stage
    "session_notes": [
      {"id": "elbow_extension:near", "rule": "elbow_extension", "player": "near", "stroke": "smash",
       "text": "Near player: Bent hitting arm at contact on 3 of 5 smashes", "count": 3, "total": 5, "severity": 1.0,
       "moments": [{"frame": 42, "time_s": 1.4, "hit_id": 0}]}
    ],
    "top_fixes": ["elbow_extension:near"]                     // note ids, most important first, at most 3
  },

  "chat": {                                                    // v1.1, F22; null until the first question
    "messages": [
      {"role": "user", "text": "Why did my smashes land short?", "at": "2026-11-17T10:30:00Z", "citations": []},
      {"role": "assistant", "text": "Your elbow was bent at contact on 3 of 5 smashes [t=1.4s]...",
       "at": "2026-11-17T10:30:04Z", "citations": [{"frame": 42, "time_s": 1.4, "hit_id": 0}]}
    ]
  },

  "stroke_model": "cnn"                                        // v1.4; cnn, lstm or rf; null if no model ran
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
| `summary.json` | `{clip_id, fps, summary, score, rallies, rally_stats, match}` subset; `match` (null without the referee layer) has `best_of`, `start_games`, `games`, `games_won`, `match_winner`, `conceded`, `points_won_on_serve` per side (`won`, `served`; the server is the doubles slot or the side of the rally's first hit), `longest_rally` and `decisions` (counts of corrections, awards, line-call overrides and reasons) | analytics (F13) |
| `hits.csv` | One row per hit: `id,frame,time_s,player,stroke,confidence,speed_kmh,tip,rally_index,hitter` (UTF-8 with BOM; `hitter` is the doubles partner, empty in singles or when unsure) | analytics (F13) |
| `rallies.csv` | One row per rally: `index,start_frame,end_frame,start_s,end_s,stroke_count,peak_speed_kmh,winner,landing_in,landing_confidence,score_near,score_far,game,server_id,receiver_id,call,margin_cm,decision` (UTF-8 with BOM). The last six (T12.4) come after the original columns: the rally's game, doubles server and receiver, the effective line call and its margin, and the referee's decisions in words (`call overridden out; cleared (let)`) | analytics (F13) |
| `annotated.mp4` | H.264, yuv420p, same fps and size as the normalized clip | render (F7) |
| `tracking.csv` | `frame,visible,x,y,source` (TrackNetV3 format plus `source`: `net`, `interp` or empty) for debugging and evaluation | tracking (F2) |

Every speed (`*speed_kmh` in the record, `summary.json` and both CSVs) is an **estimate** from one camera: the shuttle is projected onto the court plane, so a high shot reads slower than it is. The app and the rendered video label them "est."; the column names stay as they are so existing readers keep working.

## Training data layout (stroke classifier)

Two sources write the same `features/*.npz` layout under `backend/data/` (gitignored):

- `scripts/import_bst_features.py` imports the pre-extracted ShuttleSet features published with BST ([D29](DECISIONS.md)) as `bst_train.npz`, `bst_val.npz` and `bst_test.npz`, split by match by BST (`configs/splits_bst.json`). The shipped CNN, LSTM and Random Forest weights were trained on these.
- `scripts/extract_clips.py` and `scripts/extract_features.py` build them from our own match videos, one file per match, split by `configs/splits.json` ([D13](DECISIONS.md)).

```
backend/data/
├── shuttleset/                 # raw annotations from the ShuttleSet repo
├── videos/                     # match videos (not redistributed)
├── clips/<match_id>/<set>_<rally>_<stroke>.mp4 + index.csv
├── features/<match_id>.npz     # X: [N, T, F] pose+shuttle windows, y: [N], meta
├── features/bst_<split>.npz    # the same layout, imported from the BST features
└── splits.json                 # {"train": [match_ids], "val": [...], "test": [...]} — split by match
```

Feature window per hit: `T = 30` frames centered on the hit frame (`extract_features.py --window`). Per frame `F` = 39: the hitter's 17 keypoints × (x, y), centred on the player's box centre and divided by the box diagonal (`pose_norm: bbox_diag`, the rule of the BST features; `bbox_height` is the older rule), plus the shuttle (x, y, visible, dx, dy) normalized to the frame. The pose-only ablation drops the shuttle features. Every checkpoint stores its `window_frames`, `pose_norm` and `use_trajectory`, and inference builds the window from them, so models trained with either rule keep working. Checkpoints from Nov 15 on may also store `window_fps` (30): on a clip at another frame rate the window is then sampled over the same time span (one second) instead of the same number of frames. They may store `temperature` (networks: the logits are divided by it, so `confidence` is calibrated on the validation split) and `summary_version` (forest: which summary rows it was trained on). A file without these keys is read as before.

All three stroke models read this window. The CNN takes it as `[F, T]`, the LSTM as `[T, F]`, and the Random Forest reduces it to one row of summary values (`strokes/rf.py`: per-value mean, standard deviation, minimum, maximum and value at the hit; wrist and elbow speed; elbow, shoulder and knee angles; shuttle steps before and after the hit; in version 2, over the frames that hold data only, plus the share of frames with a pose).


## Known limits

- **Statistics per player are still per end.** `near` and `far` are ends of the court.
  Since v1.7 the score follows the players across a change of ends
  ([below](#schema-v17-change-of-ends)), but `summary.per_player`, the heatmaps, the
  coaching notes, practice goals and `hits[].player` are still by end: in a session that
  runs past a change of ends they mix the two players (or pairs).
- **Doubles after a change of ends.** The tracker numbers the partners at each end, so
  which person is `_1` and which `_2` at the new end is its guess. After a change at 11
  the service order continues under the slot with the same number at the other end; check
  it against the court and name the server for a later game when it differs.
- **Service lines for a line call** apply only when a rally has a single hit and the stroke
  model labelled it `serve`. Without a stroke model, or when a serve is labelled as another
  stroke, the rally lines are used.

## Schema v1.6 (courtside depth)

All additions are optional; 1.0–1.5 records migrate without invented history.

- `decision_log[]`: stable sequential `id`, `kind`, UTC `at`, `game`, optional
  `rally_index` and `frame`, reason/detail, resulting near/far `score`, `undone`, and
  optional `undoes` pointing to the decision an Undo took back. Existing scoring
  corrections/overrides remain the scoring source of truth. History is additive.
- `interval_state`: interval `key`, `duration_s`, `remaining_s`, status
  (`ready|running|paused|complete|ended`), optional UTC `deadline`. An interval is tied
  to its game/score transition; it cannot score or start play.
- `practice_goals[]`: one goal per player filter, `text`, `source` (`personal|cue`),
  optional rally and Moment, and self-reported `completed`. This user-authored list
  sits outside derived `coaching`, so recomputing notes cannot erase goals.

These fields remain compatible with the current 1.7 models and golden fixtures.
Derived JSON exports include goals and a deterministic recap of match result, stroke
counts and the existing evidence-linked top fixes. No goal improvement is inferred.

## Schema v1.7 (change of ends)

All additions are optional. A record without them never changed ends, so 1.0–1.6 records
read exactly as before.

**Rule.** `near` and `far` always mean the ends of the court at that moment. A rally's
`winner` is the end that won it, a referee's point goes to the end tapped, and `score`,
`score.games`, `score.games_won`, `score.server` and the doubles slots are by the ends as
they are now. When the players change ends, everything that belongs to a side moves with it:
after a game won 21–17 from the near end, `games` reads `[{"near": 17, "far": 21}]` and
`games_won` `{"near": 0, "far": 1}`, because the winners now stand at the far end.

| Where | Field | Meaning |
| --- | --- | --- |
| `score` | `auto_change_ends` | The session setting: change ends by the rules (after each game that does not end the match, and when the leader first reaches 11 in the deciding game or a one-game match). Left out when false |
| `score` | `ends_swapped` | The side that started at the near end is at the far end now. Left out when false |
| `rallies[]` | `ends_swapped` | The ends had been changed when this rally was played: its `winner` and `score_after` are by the ends then |
| `rallies[]` | `change_ends` | The players changed ends by rule right after this rally. Its `score_after` is the score as it was played; the next rally starts from the same score seen from the new ends |
| `score.corrections[]` | `kind: "ends"` | A change of ends marked by hand, placed like an award (`rally_index`, `frame`), with no winner. It turns the ends at that point whether or not `auto_change_ends` is set, so it also cancels an automatic change the players did not make. Undo takes it back |

`score.change_ends` is still the notice "change ends now"; with `auto_change_ends` the
score has already been turned when it shows. A change marked by hand clears the notice.
The score at a playback position (the overlay and the app's scoreboard) is turned from a
rally's `score_after` when the ends at that position differ. `rallies.csv` has an
`ends_swapped` column and `summary.json` → `match` has `ends_swapped` and
`decisions.changes_of_ends`.

Python models, Dart models, schema/OpenAPI snapshots and both golden fixtures use 1.7.
