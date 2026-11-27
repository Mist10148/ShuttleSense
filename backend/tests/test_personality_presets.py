"""The preset registry matches the requirement and stays within its prompt budget."""

from shuttlesense.coach.personality.presets import PRESETS, REGISTRY

EXPECTED = {
    "default": (70, 50, 20, 40, 60, 75, 80, 65, 50, 45),
    "professional": (40, 15, 5, 95, 35, 85, 55, 45, 80, 55),
    "friendly": (95, 65, 10, 20, 80, 65, 90, 65, 45, 50),
    "efficient": (30, 10, 5, 55, 25, 100, 45, 40, 85, 15),
    "intellectual": (50, 35, 25, 70, 65, 80, 55, 85, 75, 85),
    "mentor": (85, 45, 5, 50, 75, 65, 95, 80, 60, 80),
    "witty": (75, 95, 55, 30, 80, 70, 70, 90, 65, 55),
    "cynical": (35, 85, 95, 35, 25, 90, 65, 75, 85, 50),
    "compassionate": (100, 25, 0, 25, 50, 45, 100, 60, 30, 65),
    "creative": (75, 70, 20, 25, 85, 55, 75, 100, 60, 75),
    "bold": (45, 50, 40, 40, 85, 95, 55, 70, 100, 45),
    "reserved": (55, 20, 10, 60, 15, 65, 75, 55, 40, 35),
    "robotic": (5, 0, 0, 85, 0, 95, 25, 30, 70, 40),
    "playful": (85, 90, 45, 10, 100, 65, 75, 90, 55, 55),
    "stoic": (40, 15, 10, 65, 20, 85, 65, 50, 80, 45),
    "cute_shy": (95, 55, 10, 15, 55, 40, 95, 75, 20, 55),
    "custom": (50,) * 10,
}


def test_seventeen_presets_with_the_required_vectors_in_order():
    assert [p.id for p in PRESETS] == list(EXPECTED)
    for p in PRESETS:
        assert p.attributes == EXPECTED[p.id], p.id
        assert all(0 <= v <= 100 for v in p.attributes)


def test_every_preset_but_custom_has_prose_and_two_previews():
    for p in PRESETS:
        assert p.label and p.icon and p.description and p.serious
        if p.id == "custom":
            assert p.fragment == "" and p.previews == ()
            continue
        assert len(p.fragment.split()) <= 120, p.id
        assert len(p.previews) == 2, p.id
        assert "[t=" not in "".join(p.previews)


def test_registry_and_values():
    assert REGISTRY["bold"].values()["assertiveness"] == 100
    assert len(REGISTRY) == 17


def test_guardrails_are_written_into_the_risky_presets():
    assert "never about who" in REGISTRY["cynical"].fragment
    assert "romantic" in REGISTRY["cute_shy"].fragment
    assert "pain" in REGISTRY["bold"].fragment
    assert "safe" in REGISTRY["creative"].fragment


def test_the_app_copy_of_the_presets_is_up_to_date():
    import importlib.util
    from pathlib import Path

    path = Path(__file__).resolve().parents[1] / "scripts" / "export_presets.py"
    spec = importlib.util.spec_from_file_location("export_presets", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.OUT.read_text(encoding="utf-8") == module.export(), (
        "run python scripts/export_presets.py"
    )
    assert "fragment" not in module.export()  # prompts stay on the server
