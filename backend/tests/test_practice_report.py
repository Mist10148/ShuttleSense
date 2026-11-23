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
