# Related improvements

These came up while inspecting the repository for this plan. None of them is required for personalities, but several make the feature better or close a gap it would expose. They are listed by value and kept small.

| # | Improvement | Why | Effort |
| --- | --- | --- | --- |
| 1 | **Keep the general coach conversation across restarts.** Save the last 40 turns of `CoachChatController` locally (`coach.history`), with "New conversation" clearing it | Today the conversation lives in memory only (`coach_screen.dart`), so a personality switch keeps history in the session but a restart loses it. Players expect a coach to remember the current thread | S |
| 2 | **One prompt-building path for all three chat surfaces.** Move the practice follow-up's `SYSTEM` (`practice/followup.py`) onto the shared rules plus a surface sentence | The follow-up has its own rules text that has already drifted (different citation wording). Personality should be added once, not twice | M |
| 3 | **Fix stale "Claude API only" wording.** README (privacy bullet and docs index), PRD F22/FR-22 text and PRIVACY.md headline predate D42 (Gemini default) | Players and reviewers read the wrong provider; personality adds more provider-bound data, so the privacy text must be right | S |
| 4 | **Index the newer docs in README.** *Done with this plan:* `THEMES.md`, `AI_COACH.md` and `COACH_PERSONALITY.md` are now in the docs table | Discoverability | S |
| 5 | **Localise fixed replies.** `SAFETY_REPLY`, `OFF_TOPIC_REPLY`, side questions and the disclaimer are English-only constants | The language preference would otherwise mix languages exactly when it matters most (safety) | M |
| 6 | **Distress route and support line.** Add `distress` to the router next to `safety`, with a fixed, reviewed support message | Today only pain and injury are routed. Serious mode plans for distress, and it deserves a code-level path, not just a prompt | M |
| 7 | **Expose prompt build info in debug builds.** A debug-only "Show prompt layers" view in the chat, listing which layers were active (preset, flags, serious mode), without the digest | Speeds up tuning and bug reports; off in release builds | S |
| 8 | **Request ids in coach logs.** Log a short request id with preset id and flags | Makes "the coach was rude" reports traceable without logging text | S |
| 9 | **Cross-conversation memory (later).** An opt-in, on-device "Coach notes" list (≤ 20 short facts the player approves, e.g. "left-handed", "recovering from ankle sprain"), sent like preferences | The requirement asks for memory "where supported". The architecture has no server memory, so this is the safe on-device version with full player control. Needs its own privacy review | L |
| 10 | **Per-conversation personality.** Pin a profile to a job's chat (stored in the record) | Useful for coaches reviewing different players | M |

Item 3 is documentation-only and can be done in a separate change; it touches text other teammates wrote, so it is left for review. Items 1, 2 and 6 fit naturally into roadmap phases P1–P2.
