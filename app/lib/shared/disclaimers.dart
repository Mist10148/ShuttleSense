/// Shown wherever the app gives form feedback, session notes or coach answers.
const kCoachingDisclaimer =
    'Heuristic guidance from pose rules and automated estimates, not professional coaching '
    'or medical advice.';

/// What the coach chat sends off the backend (docs/PRIVACY.md).
const kChatPrivacy =
    'Coach chat sends a text summary of this session (strokes, form results, rallies, line '
    'calls and notes) and your questions from your server to the Gemini API (or the Claude '
    'API, if the server owner chose it). No video, frames or images are sent. It only works '
    'if the server owner has set an API key.';

/// What the general coach sends off the backend (docs/PRIVACY.md, D42).
const kCoachPrivacy =
    'The coach sends your question and short text summaries of your recorded sessions from '
    'your server to the Gemini API (or the Claude API). No video, frames or images are sent. '
    'Its badminton knowledge base stays on the server.';

/// Line calls with one camera are estimates (docs/PRD.md).
const kLineCallNote =
    'Line calls are automated estimates from one camera with a stated confidence, not '
    'official calls. Uncertain calls wait for you to confirm them.';
