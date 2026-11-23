import asyncio

from shuttlesense.practice.evidence import assess_attempt
from shuttlesense.practice.report import ReportChoice, create_practice_report
from shuttlesense.schema import Player


def attempt():
    points = [(0.0, 0.0, 0.0)] * 17
    points[0] = (5.0, 4.0, 0.9)
    points[6] = (5.0, 8.0, 0.9)
    points[8] = (6.0, 6.0, 0.9)
    points[10] = (7.0, 3.0, 0.9)
    return assess_attempt(Player(bbox=(0, 0, 10, 20), keypoints=points), "clear", "right", 1)


class Provider:
    name = "gemini"

    def __init__(self, choice):
        self.choice = choice
        self.prompt = ""

    async def generate_json(self, system, prompt, schema):
        self.prompt = prompt
        return self.choice


def test_provider_can_only_select_existing_evidence_and_guidance():
    provider = Provider(
        ReportChoice(evidence_ids=["attempt-1-observation-1"], guidance_ids=["camera_view"])
    )
    report = asyncio.run(create_practice_report([attempt()], provider))
    assert report.generated_by == "gemini"
    assert report.evidence[0]["moment_s"] == 1
    assert "keypoints" not in provider.prompt


def test_fabricated_reference_falls_back_to_rules():
    provider = Provider(ReportChoice(evidence_ids=["invented"], guidance_ids=[]))
    report = asyncio.run(create_practice_report([attempt()], provider))
    assert report.generated_by == "rules"
    assert report.evidence[0]["id"] != "invented"


def test_no_observable_evidence_does_not_call_provider():
    provider = Provider(ReportChoice())
    report = asyncio.run(
        create_practice_report([assess_attempt(None, "drop", "left", 0)], provider)
    )
    assert not report.evidence
    assert not provider.prompt
    assert "Not enough" in report.summary


def test_guidance_without_matching_observation_falls_back():
    provider = Provider(
        ReportChoice(evidence_ids=["attempt-1-observation-1"], guidance_ids=["elbow_review"])
    )
    report = asyncio.run(create_practice_report([attempt()], provider))
    assert report.generated_by == "rules"
    assert all(item["moments"] for item in report.guidance)


def test_ai_moment_guidance_requires_valid_evidence_and_knowledge():
    from shuttlesense.coach.index import Chunk
    from shuttlesense.practice.report import MomentExplanation

    class Retriever:
        async def search_knowledge(self, query, k, vector):
            return [Chunk(id="kb:clear#reach", title="Reach", text="Review overhead reach.")]

    valid = Provider(
        ReportChoice(
            evidence_ids=["attempt-1-observation-1"],
            moment_explanations=[
                MomentExplanation(
                    evidence_id="attempt-1-observation-1",
                    explanation="Review the comfortable reach.",
                    knowledge_ids=["kb:clear#reach"],
                )
            ],
        )
    )
    report = asyncio.run(create_practice_report([attempt()], valid, Retriever()))
    assert report.generated_by == "gemini"
    assert report.ai_moment_guidance[0]["time_s"] == 1
    invalid = Provider(
        ReportChoice(
            evidence_ids=["attempt-1-observation-1"],
            moment_explanations=[
                MomentExplanation(
                    evidence_id="attempt-1-observation-1",
                    explanation="Review the reach.",
                    knowledge_ids=["kb:invented"],
                )
            ],
        )
    )
    report = asyncio.run(create_practice_report([attempt()], invalid, Retriever()))
    assert report.generated_by == "rules"
    assert report.ai_moment_guidance == []


def test_coaching_points_and_drills_are_grounded_in_evidence_and_knowledge():
    import json

    from shuttlesense.coach.index import Chunk
    from shuttlesense.practice.report import CoachingPoint, PracticeDrill

    class Retriever:
        queries = []

        async def query_vector(self, query):
            self.queries.append(query)
            return None

        async def search_knowledge(self, query, k, vector):
            return [Chunk(id="kb:drills#reach", title="Reach drill", text="Practice the reach.")]

    choice = ReportChoice(
        evidence_ids=["attempt-1-observation-1"],
        coaching_points=[
            CoachingPoint(
                title="Review reach",
                explanation="Review your reach.",
                evidence_ids=["attempt-1-observation-1"],
                knowledge_ids=["kb:drills#reach"],
            )
        ],
        drills=[
            PracticeDrill(
                title="Shadow swing",
                instruction="Practice the reach slowly.",
                evidence_ids=["attempt-1-observation-1"],
                knowledge_ids=["kb:drills#reach"],
            )
        ],
    )
    provider, retriever = Provider(choice), Retriever()
    report = asyncio.run(
        create_practice_report(
            [attempt()],
            provider,
            retriever,
            session_context={"fps": 10, "processed_frames": 20, "unobserved_frames": 2},
        )
    )
    assert report.generated_by == "gemini"
    assert report.coaching_points[0]["moments"] == [1]
    assert report.drills[0]["moments"] == [1]
    assert report.sources[0]["text"] == "Practice the reach."
    prompt = json.loads(provider.prompt)
    assert retriever.queries and prompt["session"]["unobserved_frames"] == 2
    assert "attempt-1-observation-1" in prompt["rules_based"]["evidence_ids"]
    assert "keypoints" not in provider.prompt


def test_fabricated_drill_reference_and_out_of_video_moment_are_rejected():
    from shuttlesense.practice.report import PracticeDrill

    choice = ReportChoice(
        evidence_ids=["attempt-1-observation-1"],
        drills=[
            PracticeDrill(
                title="Shadow",
                instruction="Practice the reach.",
                evidence_ids=["attempt-1-observation-1"],
                knowledge_ids=["kb:made-up"],
            )
        ],
    )
    report = asyncio.run(create_practice_report([attempt()], Provider(choice)))
    assert report.generated_by == "rules" and report.drills == []
    provider = Provider(choice)
    report = asyncio.run(
        create_practice_report(
            [attempt()], provider, session_context={"fps": 10, "processed_frames": 5}
        )
    )
    assert not report.evidence and not provider.prompt


def test_long_sessions_send_bounded_evidence_and_events():
    import json

    attempts = [
        attempt().model_copy(
            update={
                "moment_s": i,
                "observations": [
                    o.model_copy(update={"moment_s": i}) for o in attempt().observations
                ],
            }
        )
        for i in range(80)
    ]
    events = [
        {"time_s": i, "source": "manual", "confirmed": True, "stroke": "clear"} for i in range(200)
    ]
    provider = Provider(ReportChoice(evidence_ids=["attempt-1-observation-1"]))
    report = asyncio.run(
        create_practice_report(
            attempts, provider, events=events, session_context={"fps": 10, "processed_frames": 3000}
        )
    )
    prompt = json.loads(provider.prompt)
    assert report.generated_by == "gemini"
    assert len(prompt["evidence"]) <= 60 and len(prompt["events"]) == 100
    assert prompt["events"][0]["time_s"] == 0 and prompt["events"][-1]["time_s"] == 199


def test_failed_provider_reports_clear_fallback_reason():
    class Broken:
        name = "gemini"

        async def generate_json(self, *args, **kwargs):
            raise RuntimeError("unavailable")

    report = asyncio.run(create_practice_report([attempt()], Broken()))
    assert report.generated_by == "rules" and report.fallback_reason == "unavailable"


def test_rate_limit_is_not_reported_as_a_missing_key(monkeypatch):
    from shuttlesense.coach.llm import ChatError
    monkeypatch.setattr("shuttlesense.practice.report.AI_RETRY_BASE_S", 0)

    class Limited:
        name = "gemini"

        async def generate_json(self, *args, **kwargs):
            raise ChatError("rate limited", 429)

    report = asyncio.run(create_practice_report([attempt()], Limited()))
    assert report.generated_by == "rules" and report.fallback_reason == "rate_limited"


def test_rate_limit_retries_once_and_recovers(monkeypatch):
    from shuttlesense.coach.llm import ChatError
    monkeypatch.setattr("shuttlesense.practice.report.AI_RETRY_BASE_S", 0)
    class TemporarilyLimited:
        name = "gemini"
        calls = 0
        async def generate_json(self, *args, **kwargs):
            self.calls += 1
            if self.calls == 1:
                raise ChatError("rate limited", 429)
            return ReportChoice(evidence_ids=["attempt-1-observation-1"])
    provider = TemporarilyLimited()
    report = asyncio.run(create_practice_report([attempt()], provider))
    assert provider.calls == 2 and report.generated_by == "gemini"
