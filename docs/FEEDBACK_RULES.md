# Form feedback rules

The feedback stage (F8, `backend/shuttlesense/feedback/rules.py`) checks the hitter's pose around each classified hit and adds one item per rule to `hits[].feedback`: the rule name, whether it passed, the measured value (schema 1.1) and a short tip when it did not.

> **Heuristic guidance, not professional coaching.** The rules use 2D keypoints from one camera, so angles are approximate and depend on where the camera stands. Tips are suggestions to try, never injury or medical advice.

In doubles, a hit whose partner could not be told apart (`hitter` is empty) gets no form
feedback: there is no single pose to grade.

## How a rule is evaluated

- **Pose window.** The hitter's 17 COCO keypoints from 6 frames before to 6 frames after the hit. Contact rules use the best value in the hit frame ± `window_frames` (default 2), because the hit frame itself can be off by a frame or two.
- **Racket arm.** The wrist closest to the shuttle at the hit frame. If the shuttle is not visible, the more confident wrist is used.
- **Low confidence.** If any joint a rule needs has a score below `min_keypoint_score` (0.3) in every frame of the window, the rule is skipped. Giving no tip is better than giving a wrong one.
- **Image coordinates.** y grows downwards, so "above" means a smaller y. Distances are divided by the player's box height, so the rules work for both the near and the far player.
- **Thresholds.** Every threshold lives in `configs/pipeline.yaml` under `stages.feedback`.

## Rules per stroke class

| Rule | Classes | Measured quantity | Passes when | Tip when it fails |
| --- | --- | --- | --- | --- |
| `contact_above_head` | smash, clear | Wrist height above the nose, in box heights | > 0 | Meet the shuttle higher, above your head |
| `elbow_extension` | smash, clear | Shoulder–elbow–wrist angle of the racket arm | ≥ `elbow_extension_deg` (150°) | Straighten your hitting arm more at contact |
| `contact_above_shoulder` | drop | Wrist height above the racket-side shoulder | > 0 | Take the drop earlier, above shoulder height |
| `short_follow_through` | drop | Wrist path length over the 5 frames after contact, in box heights | ≤ `drop_follow_through` (0.6) | Shorten the follow-through to keep the drop soft |
| `lunge_knee_bend` | net shot, lift | Smallest hip–knee–ankle angle of either leg | ≤ `lunge_knee_deg` (140°) | Bend your front knee more in the lunge |
| `racket_arm_forward` | net shot | How far the wrist is past the hip towards the net (up the image for the near player, down for the far player) | > 0 | Reach forward with the racket arm toward the net |
| `wrist_below_shoulder` | lift | Wrist height below the racket-side shoulder | > 0 | Get under the shuttle: contact below the shoulder |
| `contact_below_waist` | serve | Wrist height below the racket-side hip | > 0 | Try a lower serve contact (2D pose cue, not a fault call) |
| `stable_feet` | serve | Largest ankle path length over the 5 frames before contact, in box heights | ≤ `serve_feet_motion` (0.1) | Keep both feet still until the shuttle is struck |

## Sources

- BWF *Laws of Badminton*, Law 9.1.6 specifies a standard service height below 1.15 metres. The wrist/hip comparison retained under the legacy identifier `contact_below_waist` is only a camera-space coaching cue. Likewise ankle motion does not establish foot contact. Neither heuristic establishes a service fault or awards a point. See the [published Laws](https://system.bwfbadminton.com/documents/folder_1_81/Statutes/CHAPTER-4---RULES-OF-THE-GAME/SECTION%204.1-%20Laws%20of%20Badminton.pdf).
- Overhead strokes (clear and smash): standard coaching cues are to hit at the highest point with an extended arm. This is the basis for `contact_above_head` and `elbow_extension`. The 150° threshold allows for the 2D projection.
- Drop: the preparation is overhead like a clear, but contact is softer with a shorter follow-through. Hence `contact_above_shoulder` and `short_follow_through`.
- Net shot and lift: a lunge onto the racket-side leg with a bent front knee, and the racket reaching forward or getting under the shuttle. Hence `lunge_knee_bend`, `racket_arm_forward` and `wrist_below_shoulder`.

## Session notes (patterns)

After the pipeline runs, `feedback/patterns.py` (F21) turns the per-hit results into a few session notes in `coaching.session_notes`, plus `coaching.top_fixes`. Notes are a pure function of the clip record, so the same record always gives the same notes. They are also rebuilt after a line-call override or score correction, because those change the out-shot counts.

| Note | Counts | Fires when | Example text |
| --- | --- | --- | --- |
| `<rule>:<player>`, one per form rule above | Hits of that player the rule was checked on, and the ones that failed | failures ≥ `min_count` (2) **and** failures / checked ≥ `min_rate` (0.5) | "Near player: Bent hitting arm at contact on 3 of 5 smashes" |
| `shots_out:<player>` | Rallies with a line call whose last shot that player hit, and the ones whose call is OUT. An UNCERTAIN call nobody confirmed or overrode is left out of both counts, since it decides no rally | same thresholds | "Far player: last shot landed out in 3 of 4 rallies they finished" |

- **Moments.** Each note lists up to `max_moments` (5) timeline moments (hit frames, or landing frames for out shots); the app turns them into tap-to-seek chips.
- **Top fixes.** Notes are ranked by failures × `severity`, then by failure rate, then by id, and the first `top_fixes` (3) are the session summary. `shots_out` has severity 1.5; pose cues including `contact_below_waist` and `stable_feet` have severity 1.0. These weights rank coaching priorities, not fault judgments.
- **Thresholds** live under `stages.feedback.patterns` in `configs/pipeline.yaml`.
- **Not measured yet.** Footwork timing cues such as a late split-step need a footwork signal (ankle motion around the opponent's hit) that the pipeline does not compute yet, so there is no such note. It is listed as future work rather than guessed.

Sources: the per-rule sources above; Law 13 (faults) for shots landing outside the boundary lines.

## Adding a rule

1. Write a check `HitPose -> (passed, value) | None` in `rules.py` that returns `None` when its joints are missing.
2. Add a `Rule(name, classes, check, tip)` to `RULES`. The tip must be at most 70 characters.
3. Put any threshold in `DEFAULTS` and in `configs/pipeline.yaml`.
4. Add one passing and one failing synthetic pose to `tests/test_feedback.py`.
5. Add a row to the table above.
6. Add the fault phrase for session notes to `FAULTS` in `patterns.py` (and a `severity` entry if it is not 1.0).
