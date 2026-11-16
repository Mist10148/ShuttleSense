# Watch analysis profile November 16 2026

The user's initial observation was 10.2 seconds analyzed after approximately 45 seconds
elapsed. This is a UI progress snapshot, not a complete analysis or export benchmark.

An offline diagnostic used the first 80 frames of the saved 10.2-second partial Watch
recording, with its saved doubles court corners, real CUDA models and recording enabled.
The machine used an NVIDIA GeForce RTX 5070 Ti Laptop GPU. The application and other
desktop processes were open. The profile includes inference warmup but excludes app
playback, polling and final annotated export. It is not a direct repeat of the user's
45-second end-to-end observation.

| Pose batch setting | Setup | Processing wall time | Throughput | Player/pose total | Shuttle total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Existing setting 8 | 2.59 s | 14.02 s | 5.71 fps | 12.74 s | 5.04 s |
| Experimental setting 4 | 2.31 s | 14.54 s | 5.50 fps | 13.22 s | 5.02 s |

Only one short run per setting was performed. Player and shuttle timings overlap and must
not be added. For the existing setting, JPEG encoding and decoding totaled approximately
0.52 seconds, while the player/pose path accounted for much more time. The diagnostic
reported 2,879 candidate detections, of which 1,125 were eligible for pose processing;
these are accumulated frame-level counts, not a count of distinct people. The current
candidate filter was enabled. Its tracking and accuracy implications still require labeled
footage. The short comparison does not justify changing the pose batch setting.

The saved partial recording may have different decoding characteristics from the original
upload. Repeat with the original input, the same calibrated court, longer representative
footage, alternating settings and a minimum of three runs; compare player identities,
keypoints, shuttle positions and downstream events. Measure final export separately.
FFmpeg was not found on the shell PATH during this investigation, so NVENC export could not
be benchmarked here.

## Follow-up implementation measurements

After installing the optional `imageio-ffmpeg` binary, two runs per encoder rendered the
265-frame, 1280×720 saved session with the same overlays. libx264 took 1.64 and 1.65 s;
NVENC took 1.81 and 1.65 s, including the NVENC availability probe. The files were about
2.17 MB and 4.17 MB respectively, with the configured quality values. Encoder quality
settings are not directly equivalent. This short test does not establish an NVENC speedup;
libx264 remains the default. Playback frame counts are covered by the writer tests.

A later 120-frame offline perception comparison on the original input compared court
geometry caching with recomputing geometry every frame. It found identical recorded
perception output on all 120 frames. The uncached and cached median times were 78.71 and
79.26 ms respectively, excluding ten warmup frames. This single ordered comparison shows
no measurable end-to-end speedup; it does not include playback or final export. The cache
avoids repeating fixed court projection while keeping per-frame player protection dynamic.

## Focused player analysis experiment

On 180 frames of the original upload using CUDA detector and TensorRT RTX pose, one ordered
comparison measured median perception time 83.34 ms normally and 56.03 ms with focused
selection (first ten frames excluded); eligible pose candidates fell from 2,637 to 1,180.
Player presence matched in the tested frames and downstream hits, rallies, line calls and
score matched, but 139 of 180 perception frames differed.

On a later 120-frame section, the median was 98.44 ms normally and 104.27 ms focused,
eligible candidates fell from 1,697 to 1,213, player presence matched, and the hit output
differed. The original court calibration was reused even though camera movement is possible.
Both are single short ordered comparisons, not labelled accuracy tests or app wall-clock
measurements. Focused analysis can change results or be slower and remains off by default.
