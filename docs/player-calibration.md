# Player selection calibration

The same court-aware tracker is used for uploaded and live video. Mark the four **singles**
corners, including for doubles; the tracker adds the doubles alleys automatically. Player
selection uses confident ankle positions or the bottom centre of the detected box. Slots are
confirmed over several observations and remain assigned for the session. Missing and
ambiguous tracks are emitted as absent, so downstream analysis does not use held positions.
New players must be inside the playing boundary. A recent locked player may briefly match just
outside the lines with strict position and appearance checks; their untrusted floor position
is omitted from court analytics. Without four calibrated
corners, player detection is disabled. A lost slot can be reacquired within a limited window
when the person's position and appearance still match; the allowed movement grows gradually.
After a longer gap, recovery requires consecutive consistent detections before the box returns.
For a locked far-side player, airborne ankle projections may fall farther beyond the back
line. Matching there requires strong overlap with the previous box and consistent appearance,
has a time limit, and retains the last reliable floor position. New outside people still
cannot acquire a slot; sideline limits stay narrow.
For display only, a missing box is held and faded for up to 0.6 seconds; it never fills a
missing observation in the player record. Historical records may contain unsafe-view flags,
which still prevent display holds across those frames.

Near-identical detections of the same pose are consolidated before identity matching, to
avoid duplicate far-side boxes creating a false ambiguity. This requires both strong box
overlap and agreement among multiple upper-body joints. If overlapping players are represented
by only one detection, the model has not measured the other player's pose; the missing slot is
held briefly and is not filled with copied or invented keypoints.

When an already locked far-side player goes missing, the existing pose model also examines a
court-derived crop for a short period. Crop detections must pass the same court and identity
checks, and clipped fragments or near-side people are discarded. This may add processing time;
it does not retrain the model or guarantee a pose when a player is fully occluded.

The settings in `backend/configs/pipeline.yaml` are initial heuristics, not validated
measurements. Position and shirt colour cannot prove identity; similar uniforms, occlusion,
people already on court, changing lighting, or a person entering a lost player's last position
can still cause a mistake. The court corners apply to a fixed camera view: a camera cut, pan,
zoom, or incorrectly placed corners invalidates the geometry and requires recalibration.
There is no automatic camera-movement detection: use a tripod, keep the whole court visible,
and do not pan or zoom. Recalibrate before analyzing a different camera view.

## Validation and tuning

1. Collect consented singles and doubles clips from the intended phones, views and lighting,
   including officials near the court, boundary movement, occlusion and partner crossings.
2. Label the singles court corners and player identity and foot position per evaluated frame;
   record bystanders and which players are genuinely visible. Split by match or recording
   session into calibration and held-out test sets, keeping people and footage separated where
   possible. No labelled team footage is committed here.
3. Compare the prior and new pipelines on the same clips. Count official/bystander selections,
   identity switches, visible-player recall, missing-frame share, and reacquisitions after
   occlusion, separately for singles/doubles and calibrated/uncalibrated footage. Inspect
   downstream hit attribution as well as live and offline output.
4. Tune the pose selection settings only on the calibration split. Freeze the chosen settings,
   then report counts, denominators and results on the held-out clips. Record the video setup,
   code revision and settings alongside the report; do not infer phone-video performance from
   the pretrained stroke classifier's broadcast-data scores.
