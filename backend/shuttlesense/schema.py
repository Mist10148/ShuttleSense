"""Clip record schema v1.3 — the shared per-clip data format.

This module is the source of truth for docs/DATA_FORMAT.md. Every pipeline stage
reads and writes a ClipRecord; the API serves it as JSON to the app.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field

SCHEMA_VERSION = "1.3"

PlayerSide = Literal["near", "far"]
# Doubles (v1.2, D22): one slot per person. near_1/far_1 live in the near/far fields that
# singles already uses; a slot follows the person, not a half of the court.
PlayerId = Literal["near_1", "near_2", "far_1", "far_2"]
PLAYER_IDS: tuple[PlayerId, ...] = ("near_1", "near_2", "far_1", "far_2")
StrokeClass = Literal["smash", "clear", "drop", "net_shot", "lift", "serve"]
RallyState = Literal["in_play", "between_rallies"]
Mode = Literal["upload", "live"]
Call = Literal["in", "out"]
CourtType = Literal["singles", "doubles"]
RallyEventType = Literal["rally_start", "rally_end", "hit", "landing", "score"]
ServiceCourt = Literal["right", "left"]

STROKE_CLASSES: tuple[StrokeClass, ...] = ("smash", "clear", "drop", "net_shot", "lift", "serve")
NUM_KEYPOINTS = 17  # COCO layout

# Singles court in meters: width (sideline to sideline) x length (baseline to baseline).
COURT_SIZE_M: tuple[float, float] = (5.18, 13.40)

Point = tuple[float, float]


def slot_attr(player: PlayerId | PlayerSide) -> str:
    """The Players / CourtPositions field of a slot: near_1 -> near, near_2 -> near_2."""
    return player[:-2] if player.endswith("_1") else player


def side_of(player: PlayerId | PlayerSide) -> PlayerSide:
    """The team side of a slot (near_2 -> near)."""
    return "near" if player.startswith("near") else "far"


def slot_id(attr: str) -> PlayerId:
    """The slot of a Players field: near -> near_1, far_2 -> far_2."""
    return attr if attr.endswith("_2") else f"{attr}_1"  # type: ignore[return-value]


def _omit_none() -> Any:
    """An optional v1.2 field left out of the JSON while it is None, so records that do not
    use it (every singles record) serialize exactly as before."""
    return Field(default=None, exclude_if=lambda v: v is None)


class Shuttle(BaseModel):
    x: float | None = None
    y: float | None = None
    visible: Literal[0, 1] = 0


class Player(BaseModel):
    bbox: tuple[float, float, float, float]  # x, y, w, h in pixels
    keypoints: list[tuple[float, float, float]] = Field(default_factory=list)  # [x, y, score] x 17
    score: float = 0.0


class Players(BaseModel):
    near: Player | None = None
    far: Player | None = None
    near_2: Player | None = _omit_none()  # doubles partners (v1.2)
    far_2: Player | None = _omit_none()

    def slots(self) -> dict[PlayerId, Player | None]:
        return {pid: getattr(self, slot_attr(pid)) for pid in PLAYER_IDS}


class CourtPositions(BaseModel):
    near: Point | None = None
    far: Point | None = None
    shuttle: Point | None = None
    near_2: Point | None = _omit_none()  # doubles partners (v1.2)
    far_2: Point | None = _omit_none()


class Frame(BaseModel):
    frame: int
    shuttle: Shuttle | None = None
    players: Players = Field(default_factory=Players)
    court_positions: CourtPositions | None = None
    shuttle_speed_kmh: float | None = None
    rally_state: RallyState | None = None


class Court(BaseModel):
    corners_px: tuple[Point, Point, Point, Point]  # near-left, near-right, far-right, far-left
    homography: list[list[float]]  # 3x3, image px -> court meters
    court_size_m: Point = COURT_SIZE_M


class FeedbackItem(BaseModel):
    rule: str
    passed: bool
    tip: str | None = None
    value: float | None = None  # measured quantity (degrees, ratio, ...), v1.1


class Hit(BaseModel):
    id: int
    frame: int
    time_s: float
    player: PlayerSide  # the side; in doubles `hitter` says which partner
    stroke: StrokeClass | None = None
    confidence: float | None = None
    class_probs: dict[StrokeClass, float] | None = None
    speed_kmh: float | None = None
    feedback: list[FeedbackItem] = Field(default_factory=list)
    rally_index: int | None = None
    hitter: PlayerId | None = _omit_none()  # doubles (v1.2); None: singles or unsure
    hitter_confidence: float | None = _omit_none()

    @property
    def player_attr(self) -> str:
        """Players field of whoever hit: the hitter's slot in doubles, else the side."""
        return slot_attr(self.hitter) if self.hitter else self.player


class Landing(BaseModel):
    x_m: float
    y_m: float
    in_court: bool
    confidence: float


class ScorePair(BaseModel):
    near: int = 0
    far: int = 0


class Rally(BaseModel):
    index: int
    start_frame: int
    end_frame: int
    stroke_count: int = 0
    landing: Landing | None = None
    winner: PlayerSide | None = None
    score_after: ScorePair | None = None  # score of its game after it (None: match over)
    game: int = 1  # 1-based game of the match this rally was played in
    server_id: PlayerId | None = _omit_none()  # doubles (v1.2): server and receiver
    receiver_id: PlayerId | None = _omit_none()
    review: str | None = _omit_none()  # why the user should check this rally


class ScoreCorrection(BaseModel):
    """A user's score change: a rally's winner set or cleared, or a point awarded.

    An award is a point for a rally the referee layer missed; it counts after the detected
    rallies before rally_index (the number of rallies when it was given).
    """

    rally_index: int
    winner_before: PlayerSide | None
    winner_after: PlayerSide | None  # None: the rally is undecided again
    at: datetime
    kind: Literal["winner", "award"] = "winner"
    frame: int | None = None  # where an award was given


class GameService(BaseModel):
    """Doubles (v1.3): who serves and receives first in a game after the first (D23).

    The winners of a game choose, so the user names them; the game winner's side serves."""

    game: int = Field(ge=2)
    server_id: PlayerId
    receiver_id: PlayerId


class Score(ScorePair):
    """The current game's score (the last game's once the match is over) and match state."""

    corrections: list[ScoreCorrection] = Field(default_factory=list)
    best_of: int = 1  # games in the match: 1 or 3
    first_server: PlayerSide | None = None  # set by the user; one camera cannot tell
    game: int = 1
    games: list[ScorePair] = Field(default_factory=list)  # finished games, in order
    games_won: ScorePair = Field(default_factory=ScorePair)
    server: PlayerSide | None = None  # who serves the next rally (None: not known yet)
    service_court: ServiceCourt | None = None  # right on the server's even score
    game_point: list[PlayerSide] = Field(default_factory=list)  # one point from the game
    match_point: list[PlayerSide] = Field(default_factory=list)
    match_winner: PlayerSide | None = None
    interval: bool = False  # the last rally took the leader to 11: 60 s interval
    change_ends: bool = False  # after a game, and at 11 in the deciding game
    # Doubles (v1.2): the user names who serves and receives first; the rest follows.
    first_server_id: PlayerId | None = _omit_none()
    first_receiver_id: PlayerId | None = _omit_none()
    server_id: PlayerId | None = _omit_none()  # who serves the next rally
    receiver_id: PlayerId | None = _omit_none()
    # Doubles (v1.3): the first server and receiver of later games, as the user named them.
    game_service: list[GameService] = Field(default_factory=list, exclude_if=lambda v: not v)


class Moment(BaseModel):
    """A point on the timeline the app can seek to."""

    frame: int
    time_s: float
    hit_id: int | None = None


class LineCallOverride(BaseModel):
    call: Call
    at: datetime


class LineCall(BaseModel):
    """Automated in/out call for one landing; never an official call."""

    id: int
    rally_index: int
    frame: int
    time_s: float
    call: Call
    landing_xy: Point  # court meters
    margin_cm: float  # signed distance to the nearest relevant line, positive inside
    confidence: float
    uncertain: bool
    court: CourtType = "singles"
    override: LineCallOverride | None = None

    @property
    def effective_call(self) -> Call:
        return self.override.call if self.override else self.call


class RallyEvent(BaseModel):
    frame: int
    time_s: float
    type: RallyEventType
    rally_index: int | None = None
    data: dict[str, Any] = Field(default_factory=dict)


class SessionNote(BaseModel):
    id: str
    rule: str
    player: PlayerSide | PlayerId | None = None  # a slot in doubles
    stroke: StrokeClass | None = None  # set when the rule was checked on one stroke class
    text: str
    count: int  # strokes that showed the pattern
    total: int  # strokes the rule was checked on
    severity: float
    moments: list[Moment] = Field(default_factory=list)


class Coaching(BaseModel):
    session_notes: list[SessionNote] = Field(default_factory=list)
    top_fixes: list[str] = Field(default_factory=list)  # SessionNote ids, most important first


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    text: str
    at: datetime
    citations: list[Moment] = Field(default_factory=list)


class Chat(BaseModel):
    messages: list[ChatMessage] = Field(default_factory=list)


class PlayerSummary(BaseModel):
    hits: int = 0
    stroke_counts: dict[StrokeClass, int] = Field(default_factory=dict)
    peak_speed_kmh: float | None = None


class Summary(BaseModel):
    total_hits: int = 0
    stroke_counts: dict[StrokeClass, int] = Field(default_factory=dict)
    peak_speed_kmh: float | None = None
    # Keyed by side in singles and by slot in doubles.
    per_player: dict[PlayerSide | PlayerId, PlayerSummary] = Field(default_factory=dict)


class ClipRecord(BaseModel):
    schema_version: str = SCHEMA_VERSION
    clip_id: str
    mode: Mode = "upload"
    source_name: str | None = None
    fps: float
    width: int
    height: int
    num_frames: int
    court: Court | None = None
    frames: list[Frame] = Field(default_factory=list)
    hits: list[Hit] = Field(default_factory=list)
    rallies: list[Rally] = Field(default_factory=list)
    score: Score | None = None
    summary: Summary | None = None
    line_calls: list[LineCall] = Field(default_factory=list)
    rally_events: list[RallyEvent] = Field(default_factory=list)
    coaching: Coaching | None = None
    chat: Chat | None = None


def is_doubles(record: ClipRecord) -> bool:
    """Whether the record tracks partners (a doubles match with four player slots)."""
    return any(f.players.near_2 or f.players.far_2 for f in record.frames)


def migrate(data: dict[str, Any]) -> dict[str, Any]:
    """Upgrade an older record dict to SCHEMA_VERSION in place and return it.

    1.0 -> 1.1 only adds optional fields; the defaults fill them, and line calls and rally
    events are derived from the rallies so old jobs show calls in the app. 1.1 -> 1.2 adds
    optional doubles fields only, and 1.2 -> 1.3 the optional per-game doubles service.
    """
    version = str(data.get("schema_version", "1.0"))
    if version == SCHEMA_VERSION:
        return data
    if version.split(".")[0] != SCHEMA_VERSION.split(".")[0]:
        raise ValueError(f"cannot migrate clip record {version} to {SCHEMA_VERSION}")
    data["schema_version"] = SCHEMA_VERSION
    data.setdefault("mode", "upload")
    if version == "1.0" and not data.get("line_calls") and data.get("rallies"):
        from shuttlesense.referee import build_events, derive_from_rallies

        record = ClipRecord.model_validate(data)
        record.line_calls = derive_from_rallies(record)
        record.rally_events = build_events(record)
        data["line_calls"] = [c.model_dump(mode="json") for c in record.line_calls]
        data["rally_events"] = [e.model_dump(mode="json") for e in record.rally_events]
    return data


def load_record(text: str | bytes) -> ClipRecord:
    """Parse a record.json of any supported version."""
    import json

    return ClipRecord.model_validate(migrate(json.loads(text)))
