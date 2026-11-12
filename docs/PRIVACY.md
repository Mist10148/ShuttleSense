# Privacy

What ShuttleSense keeps, where, and what leaves your backend. The app's Settings screen links here and shows the short version.

## Stays on your backend

- Uploaded videos and live-session recordings (`storage/videos/`, `storage/jobs/<id>/source.mp4`)
- Clip records, annotated videos and exports (`storage/jobs/<id>/`)
- Live camera frames: the app sends them to your backend only, over the same address and token as uploads

Everything can be deleted from the app (History → delete, with "also delete video"). The project does not run a server of its own and receives nothing.

## Sent to the Claude API (coach chat only)

The coach chat is off unless whoever runs the backend sets an Anthropic API key (`SHUTTLESENSE_ANTHROPIC_API_KEY` or `ANTHROPIC_API_KEY`). The key lives in the backend's environment, never in the app or the repository.

When you send a chat message, the backend sends Anthropic:

| Sent | Not sent |
| --- | --- |
| Your question and the earlier messages of that chat | Video, frames, images or thumbnails |
| A text digest of the clip record: per-hit time, player side (near/far) and in doubles the partner slot (`near_1` to `far_2`), stroke, confidence, estimated speed, form rule results; per-rally length, winner, score, in doubles who served and received, and line call (in/out, margin, confidence); session notes and summary counts | Keypoints, raw shuttle tracks, court corners |
| Clip duration and frame rate | File names, server address, token, IP of the phone |

The digest is capped in size (`SHUTTLESENSE_CHAT_MAX_DIGEST_CHARS`); long sessions are summarized per rally. The model is `claude-opus-5-5` unless the backend owner sets `SHUTTLESENSE_CHAT_MODEL`; if it declines a request, the API's server-side fallback may answer with another Claude model. The exact text is built by `backend/shuttlesense/coach/digest.py`.

Anthropic's handling of API data is described in its commercial terms and privacy policy. The chat history is saved in the clip record (`chat.messages`) on your backend and deleted with the job.

## Not medical or professional advice

Form notes and chat answers are heuristic guidance from pose rules, not professional coaching. The chat refuses to diagnose injuries; see a qualified professional for pain or injury.
