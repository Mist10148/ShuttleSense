# Watch Phase 3 promotion gate

## Decision — November 18, 2026

No Phase 3 experimental change is approved for promotion by the evidence currently
available. The `samples/` and `backend/data/` directories have no labeled evaluation
footage. We found no held-out player-box, keypoint or occlusion/reacquisition labels
for the benchmark recordings. Therefore player and hit recall, identity switches,
reacquisition failures and pose error have no measured denominators or uncertainty
for this gate. The Phase 1 controlled Flutter baseline is also incomplete.

The focused player-candidate shortcut is disabled (`watch.candidates_per_player: 0`;
the app's optional faster-analysis switch defaults off). It must remain off until it
passes the gate. Earlier short, single ordered tests were mixed: on one 120-frame
section the shortcut changed the hit output and did not improve median perception time;
they are neither labeled accuracy tests nor repeated app measurements. See
[the prior experiments](watch_performance_nov16.md).

The user briefly tried shadow candidate filtering and sequential pose, then requested
the previous settings back because the app felt slower. The defaults are restored to
`watch.candidate_filter: filter` and `watch.pose_batch_size: 8`. Both were enabled before
this gate and remain experimental without held-out accuracy evidence: filtering can
miss players and batching can affect numerical results. Restart the backend to apply the
restored settings. The user's speed observation was not a controlled comparison.

A five-frame real-model smoke run on the first doubles broadcast section completed
with shadow and sequential pose: the filter proposed excluding 129 of 173 detections, but shadow
mode sent all 173 through pose, and all 173 pose session calls had batch size 1.
Diagnostics reported detector CUDA and pose TensorRT RTX active without a reported
candidate-filter fallback. This short, warm-up-inclusive diagnostic is a functionality
check, not an accuracy evaluation or a representative performance comparison.

The frame-prefetch prototype is a separate Phase 2 experiment and remains off. In the
six-run instrumented Flutter comparison its median analysis time was 2.0% slower, not
at least 5% faster. Frame, hit and rally records and exported video matched on that one
section, but that is not held-out accuracy evidence. See
[the delivery comparison](watch_phase2_delivery.md).

The existing pre-gate configuration also requests TensorRT RTX for pose
(`watch.player_provider: pose`). Its runtime provider and fallback diagnostics are
available, but assignment or numerical comparisons on short clips are not labeled
validation. This setting predates this gate; the Phase 1 baseline and provider/fallback
review remain open. TensorRT RTX is not newly promoted by this assessment.

## What evidence is needed

- Use separately identified calibration and held-out recordings, split by match or
  recording. Include consented singles and doubles footage, spectators, boundary play,
  jumps, occlusions, crossings, tracking loss and reacquisition. Record camera motion,
  normalization, calibration and which frames/events were actually labeled.
- Compare the same baseline and candidate on the same held-out inputs and settings.
  Run at least three alternating actual Flutter trials on identical fixed sections;
  report all runs, startup conditions and median analysis times. A gain below 5%,
  failure, or insufficient measurement leaves the change unpromoted.
- Report player matches and labeled player-observation denominators, hit matches and
  labeled-hit denominators, identity-switch counts and track/observation opportunities,
  reacquisition failures and labeled reacquisition opportunities, and keypoint error
  with the number of matched visible labeled keypoints. Use the same matching, visibility,
  event tolerance and missing-observation rules for both runs; show per-recording values
  as well as totals. Report uncertainty, accounting for correlation within recordings.
  Zero denominators are unavailable evidence, not zero errors or a passing score.
- Compare on the held-out set: neither player nor hit recall may fall; identity-switch
  and reacquisition-failure counts may not rise; pose error may not worsen. Report
  denominators and uncertainty, and leave the change disabled if coverage or evidence is
  insufficient to assess a criterion. Review fallback, errors and functional behavior too.

`scripts/label_clip.py` can collect hit/rally labels and sampled doubles player boxes;
`scripts/eval_hits.py` reports hit matches and recall, and `scripts/eval_doubles.py`
reports box-based ID switches and IDF1. The existing tools do not by themselves provide
all of the required player-recall, pose-keypoint-error, reacquisition and paired
uncertainty measurements. Build and validate those measurements before making a
promotion decision; do not substitute unlabeled slot jumps or equal model outputs for
held-out accuracy. Preserve the existing split and avoid tuning on held-out recordings.
