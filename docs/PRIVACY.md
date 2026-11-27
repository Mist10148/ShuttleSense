# Privacy

What ShuttleSense keeps, where, and what leaves your backend. The app's Settings screen links here and shows the short version.

## Stays on your backend

- Uploaded videos and live-session recordings (`storage/videos/`, `storage/jobs/<id>/source.mp4`)
- Clip records, annotated videos and exports (`storage/jobs/<id>/`)
- Live camera frames: the app sends them to your backend only, over the same address and token as uploads

Everything can be deleted from the app (History → delete, with "also delete video"). The project does not run a server of its own and receives nothing.

## Sent to the Gemini API, or the Claude API (coach only)

The coach (session chat, general coach and coaching report) is off unless whoever runs the backend sets an API key. By default it uses Google's Gemini API (`SHUTTLESENSE_GEMINI_API_KEY` or `GEMINI_API_KEY`); with only an Anthropic key (`SHUTTLESENSE_ANTHROPIC_API_KEY` or `ANTHROPIC_API_KEY`), or with `SHUTTLESENSE_COACH_PROVIDER=claude`, it uses the Claude API instead. Only one provider receives a given question. Keys live in the backend's environment, never in the app or the repository.

When you ask the coach something, the backend sends the provider:

| Sent | Not sent |
| --- | --- |
| Your question and the earlier messages of that chat | Video, frames, images or thumbnails |
| A text digest of the clip record: per-hit time, player side (near/far) and in doubles the partner slot (`near_1` to `far_2`), stroke, confidence, estimated speed, form rule results; per-rally length, game, winner, score, in doubles who served and received, and line call (in/out, margin, confidence); session notes and summary counts | Keypoints, raw shuttle tracks, court corners |
| Clip duration and frame rate | File names, server address, token, IP of the phone |

The coach retrieves what it sends (D42): instead of the whole digest, it sends the digest's session totals, score and notes plus the few per-rally and per-player text chunks that match the question. For a progress question it adds short per-session summaries of your other finished jobs on this backend (date, stroke counts, form-rule pass rates, rallies won, peak speeds, the notes' text), numbered rather than named: no file names or job ids. The general coach (not tied to one session) sends your question, the earlier turns of that conversation (kept by the app, not the server) and those summaries. The coaching report sends the same kind of session chunks.

The badminton knowledge base (technique, rules, drills) is Markdown shipped with the backend (`backend/shuttlesense/coach/knowledge/`); chunks of it that match the question are sent along as public reference text. With Gemini, retrieval also uses Gemini embeddings: the knowledge chunks (once, then cached in `storage/coach_index.npz`), your question and the session's text chunks are sent to the embeddings endpoint. Before each answer one small request classifies the question (session, history, technique, drills, injury, off topic) and sends only the question. Questions about pain or injury get a fixed reply first; the coach does not diagnose.

The digest also states the match result (best of, per-game scores, games won, winner) and the number of manual referee decisions. It is capped in size (`SHUTTLESENSE_CHAT_MAX_DIGEST_CHARS`); long sessions are summarized per rally, then the oldest rallies' detail is left out, and the session notes always stay in. With Gemini the models are `gemini-3.8-flash` (answers and the report), `gemini-3.5-flash-lite` (classifying the question) and `gemini-embedding-2` (retrieval), unless the backend owner sets `SHUTTLESENSE_GEMINI_MODEL`, `SHUTTLESENSE_GEMINI_FAST_MODEL` or `SHUTTLESENSE_GEMINI_EMBED_MODEL`. With Claude the model is `claude-opus-5-5` unless the backend owner sets `SHUTTLESENSE_CHAT_MODEL`; if it declines a request, the API's server-side fallback may answer with another Claude model, and there are no embeddings (keyword retrieval only). The exact text is built by `backend/shuttlesense/coach/digest.py` and `backend/shuttlesense/coach/session_docs.py`.

Google's handling of Gemini API data is described in the Gemini API terms (paid and free tiers differ: on the free tier Google may use prompts to improve its products), and Anthropic's in its commercial terms and privacy policy. The session chat history is saved in the clip record (`chat.messages`) on your backend and deleted with the job; the coaching report is cached as `storage/jobs/<id>/coach_report.json` and deleted with the job. The general coach conversation is not stored on the backend.

### Coach personality

How the coach talks is chosen in Settings > AI Coach ([COACH_PERSONALITY.md](COACH_PERSONALITY.md)). The settings and saved profiles stay on your device (`coach.personality`); they are never stored on the backend. When you ask a question (session chat, the general coach or a practice follow-up), the active personality goes with it to the backend and, as part of the coach's instructions, to Gemini or Claude: the preset, slider and option choices, and anything you typed yourself (the coach's name, what it calls you, your instructions and words). The backend saves only the personality's name with each job chat answer. **Describe it, AI drafts it** sends only the description you typed, and only when you press the button. Export copies your profiles to the clipboard; the names and language are included only if you tick the box.

## Not medical or professional advice

Form notes and chat answers are heuristic guidance from pose rules, not professional coaching. The chat refuses to diagnose injuries; see a qualified professional for pain or injury.


### Courtside goals and history
Personal practice goals, completion flags, referee decisions and timestamps are stored
with the session on the configured backend and included in its JSON exports. They
follow the existing job deletion lifecycle. No accounts, new cloud service or additional
chat payload is introduced by these tools. Goals are not medical or measured progress advice.


## Single-player AI Coach

Recorded practice videos and rendered outputs remain on the configured backend. When a provider is enabled, the practice report sends current-session structured pose observations, selected events, analysis notes and retrieved badminton knowledge, not video or image frames; without a provider it uses a labeled rules-based report. Retrieval may also send generic stroke and technique queries and packaged badminton knowledge to the provider's embeddings endpoint; keyword matching is used if embeddings are unavailable. The temporary report context is not stored, while the generated report is cached with the job. Deleting the job removes its practice data and cached report. See [AI Coach setup](AI_COACH.md).
