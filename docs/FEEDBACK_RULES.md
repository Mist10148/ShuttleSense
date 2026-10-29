# Form feedback rules

The feedback stage (F8, `backend/shuttlesense/feedback/rules.py`) checks the hitter's pose around each classified hit and adds one item per rule to `hits[].feedback`: the rule name, whether it passed, and a short tip when it did not.

> **Heuristic guidance, not professional coaching.** The rules use 2D keypoints from one camera, so angles are approximate and depend on where the camera stands. Tips are suggestions to try, never injury or medical advice.

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
| `contact_below_waist` | serve | Wrist height below the racket-side hip | > 0 | Serve from below the waist (singles service rule) |
| `stable_feet` | serve | Largest ankle path length over the 5 frames before contact, in box heights | ≤ `serve_feet_motion` (0.1) | Keep both feet still until the shuttle is struck |

## Sources

- BWF *Laws of Badminton*, Law 9 (service): the whole shuttle must be below the server's waist at contact, and both feet must stay in contact with the floor until the service is delivered. This is the basis for `contact_below_waist` and `stable_feet`.
- Overhead strokes (clear and smash): standard coaching cues are to hit at the highest point with an extended arm. This is the basis for `contact_above_head` and `elbow_extension`. The 150° threshold allows for the 2D projection.
- Drop: the preparation is overhead like a clear, but contact is softer with a shorter follow-through. Hence `contact_above_shoulder` and `short_follow_through`.
- Net shot and lift: a lunge onto the racket-side leg with a bent front knee, and the racket reaching forward or getting under the shuttle. Hence `lunge_knee_bend`, `racket_arm_forward` and `wrist_below_shoulder`.

## Adding a rule

1. Write a check `HitPose -> (passed, value) | None` in `rules.py` that returns `None` when its joints are missing.
2. Add a `Rule(name, classes, check, tip)` to `RULES`. The tip must be at most 70 characters.
3. Put any threshold in `DEFAULTS` and in `configs/pipeline.yaml`.
4. Add one passing and one failing synthetic pose to `tests/test_feedback.py`.
5. Add a row to the table above.
