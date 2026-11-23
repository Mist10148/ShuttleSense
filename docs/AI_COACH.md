# AI Coach: recorded single-player practice

AI Coach analyzes a recorded practice clip without court calibration. Version 1 supports a user-selected player, racket arm, and overhead clear, smash or drop. It can process shadow swings without a shuttle. It uses selected-player detection and 2D pose. When shuttle tracking is available, it also proposes hit events and uses the match-trained CNN with the Watch evidence guard; predictions are estimates and require review. Shadow practice can still use manually marked attempts.

## Setup and workflow

Start the real backend and Windows or web app as described in [SETUP.md](SETUP.md). The AI Coach card is enabled when the backend advertises practice support; demo/fake mode does not provide player detection. The model and its ONNX Runtime dependencies must be installed and available; the first model load can take time.

1. Open AI Coach, select an MP4/MOV/AVI clip, and use the frame slider to inspect the recording.
2. Optionally mark attempt frames with the button, or enter their times in seconds separated by commas; leave them empty to review automatically detected candidates after analysis. Choose a selection frame at or before the first attempt, then click the target player's box.
3. Choose clear, smash or drop and the racket arm, then confirm and start analysis. Tracking continues through missing or ambiguous detections; those frames are excluded from player analysis. A unique overlapping detection may be reacquired, but identity after an occlusion is not guaranteed.
4. During processing, the preview shows the latest analyzed frame and elapsed time includes pauses. Pause and Play control processing. Stop and save finishes the frames already analyzed, then renders and saves that portion; if rendering has started, it completes the collected analysis.
5. After analysis, the video is rendered with the shared Watch overlays. The coaching report includes available timestamped technique feedback and pose observations. Tap a report entry to seek to its moment in the video.
6. Open the completed session from History. Review, confirm, correct, add or remove candidate events and save them to update the report. Automatic labels are estimates.

Automatic stroke labels are estimates; manually selected labels and attempt times are user-supplied. Neither proves the stroke class or shuttle contact. The current report describes 2D wrist/nose position and elbow angle where joints are visible and provides limited general review cues. It does not diagnose technique or injury. Camera angle, occlusion, motion blur, detections and tracking affect results. Player selection based on bounding boxes cannot guarantee identity in every occlusion. Use a fixed camera with the whole player visible and review outputs with a qualified coach.

## Provider and data

No key is required for the rules-based fallback. A backend `.env` file is optional and gitignored; process environment variables override values from that file. Use a newly rotated Gemini key if a key was previously exposed. For an AI-ranked report, configure the existing backend `SHUTTLESENSE_GEMINI_API_KEY` / `GEMINI_API_KEY` or `SHUTTLESENSE_ANTHROPIC_API_KEY` / `ANTHROPIC_API_KEY`, and restart the backend. The Gemini SDK is supplied by the base requirements. The configured provider receives structured measurements and bounded guidance choices, not video or frames. It can select known evidence and guidance IDs and provide narrative guidance linked to those IDs. The server validates references and constructs the visible report; reference validation cannot guarantee factual correctness, so review AI guidance against the video and evidence. Provider errors or invalid references fall back to rules. A report with no usable measurements does not call the provider. See [PRIVACY.md](PRIVACY.md) for provider terms and backend storage practices.

Practice job data and the rendered video are stored under the existing job storage directory and removed with the job. A completed report is cached and can be regenerated when a provider becomes available after a rules-based run. The app and backend do not yet establish real-world coaching accuracy; the short model-backed smoke check is not an evaluation of performance or identity tracking.

To configure the replacement Gemini key in `backend/.env`, add `SHUTTLESENSE_GEMINI_API_KEY=<your-replacement-key>` and restart the backend. Do not commit or share the key. An environment variable with the same name takes precedence. A previously exposed key should be revoked at the provider.

## API

All practice endpoints use the existing token authentication:

- `GET /practice/videos/{video_id}/players?frame=N` returns player candidate boxes in original frame coordinates.
- `POST /practice/sessions` starts a job with `video_id`, `stroke`, `arm`, `selection_frame`, `selected_bbox` and `attempt_seconds`.
- `GET /practice/sessions/{job_id}` returns job state, including progress and completion status.
- `POST /practice/sessions/{job_id}/selection` remains available for older paused sessions.
- `POST /practice/sessions/{job_id}/control/{pause|resume|stop}` controls a running job; stop saves the analyzed portion.
- `GET /practice/sessions/{job_id}/result` returns attempt observations and the report after completion. The rendered video uses the existing `/jobs/{job_id}/video` endpoint and deletion uses `DELETE /jobs/{job_id}`.

- `PUT /practice/sessions/{job_id}/events` saves the reviewed event list, rebuilds confirmed pose observations, and invalidates the cached report.
