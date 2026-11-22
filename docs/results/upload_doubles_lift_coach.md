# Uploaded doubles, lift tracking and coach verification

Measured on November 22, 2026 against revision `05d56df`. All frame numbers below are zero-based. The videos and the Gemini credential stay local.

## Doubles replay

The saved green-court upload started at the near-left corner and visited the far-left corner second. Both windings passed validation, so the tracker treated the left sideline as the near baseline. The upload pipeline now keeps the near-left anchor and resolves the winding before pose selection and court projection. The first tap still has to identify the near-left singles corner.

On the same 350-frame video and saved taps, six source frames (30, 90, 150, 210, 270 and 330) were inspected for all four players. A detection counted once when its box bottom centre was within 40 source pixels of the manually marked shoe midpoint and it belonged to the correct side.

| Green-court measure | Before | After |
|---|---:|---:|
| Correct side and position, out of 24 player observations | 4 | 10 |
| Frames with all four slots populated, out of 350 | 0 | 0 |
| Median court-position error on matched samples with an exported position | 2.46 m (4 samples) | 0.50 m (8 samples) |

The metre reference projects the manual shoe marks through the corrected calibration. The two medians cover different detected subsets. Four-player recall remains incomplete, particularly for the far pair. On a separate Clementi clip, source and exported frames 30, 60, 120 and 210 showed 12 of 16 player observations on the correct side. The Clementi check reused taps from the same camera view. These sparse checks do not establish a match-wide identity-switch rate.

The Flutter heatmap now uses the exported grid origin of (-2 m, -2 m) and 0.25 m cells. Checks cover both alleys, partner occupancy time and the accessible peak-cell label. Replacing a completed record refreshes the map even when its clip ID and frame count stay the same.

## Lift exit and return

The green-court lift approaches the upper edge at about 1.7 s. Cropping the top 22 rows from source frames 30–84 created an observable exit while preserving the uncropped view for comparison. Both versions received the same TrackNet observations. The older postprocessor filled source frames 51–57, when the shuttle centre was above the cropped view. The updated export left all seven unknown and resumed on measured frame 58. Median centre error across nine manually checked visible frames was about 2.1 pixels in both versions.

On a deeper 36-row crop the baseline already left the long gap empty. The original uncropped apex also remained visible. The playback trail now fades by elapsed frames during missing observations. The Western Badminton clip was checked for shuttle tracking and export only because there was no saved court calibration. A 901-frame singles upload and the 504-frame doubles upload also rendered successfully.

Two older doubles jobs had stopped on a TrackNet GPU allocation error. The overlapping-window inference path now retries the failed windows in a smaller batch. A controlled allocation failure verified that no windows were skipped or counted twice.

## Gemini coach and UI

The production Gemini endpoint returned HTTP 503 under load while embeddings and routing succeeded. Requests now have a transport timeout. Chat can use the configured fast Gemini model when the first model is unavailable before any answer text is delivered. Structured reports can use the same fallback. A stream that has already emitted text does not restart the answer.

A real-key smoke test exercised embeddings, routing, session chat, general chat and a Gemini-generated report using synthetic data. The saved session answer correctly identified three recorded hits and included timestamps matching the record. Internal session and history retrieval labels are removed from the completed answer. One repeat reached the rules-based report during a Gemini 503. The following end-to-end run passed in 24.68 seconds. The minimap screen reader now announces the same shuttle position as the drawing, including whether it comes from rally timing or a camera projection. Responsive Flutter widget tests cover coach replies, sources, error recovery and the minimap.
