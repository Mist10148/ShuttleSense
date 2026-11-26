from test_live import START, _send_frames, _wait_done, make_client

from shuttlesense.referee import run
from shuttlesense.referee.rally import next_serve_side
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext


def test_pending_and_clear_landings_agree_live_recorded_and_after_undo(tmp_path):
    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            job_id = ws.receive_json()["job_id"]
            events = _send_frames(ws, 410)
            ws.send_json({"type": "stop"})
            while (event := ws.receive_json())["type"] != "saved":
                events.append(event)
        assert _wait_done(client, job_id)["status"] == "done"
        url = f"/jobs/{job_id}"
        saved = client.get(f"{url}/record").json()
        record = ClipRecord.model_validate(saved)
        offline = run(record, StageContext(video_path=None, out_dir=None, config={}))
        live_calls = [e["line_call"] for e in events if e["type"] == "line_call"]
        assert any(c["uncertain"] for c in live_calls)
        assert any(not c["uncertain"] for c in live_calls)
        rallies = offline.rallies
        for call in live_calls:
            index = call["rally_index"]
            assert offline.line_calls[index].uncertain == call["uncertain"]
            winner = saved["rallies"][index]["winner"]
            assert offline.rallies[index].winner == winner
            # An uncertain call waits for the user unless a clear next serve decides it (D47).
            following = rallies[index + 1] if index + 1 < len(rallies) else None
            serve = next_serve_side(offline, rallies[index], following, {})
            assert (winner is None) == (call["uncertain"] and serve is None)
            if call["uncertain"] and serve is not None:
                assert winner == serve
        pending = next(c["rally_index"] for c in live_calls if c["uncertain"])
        current = saved["rallies"][pending]["winner"]
        target = "far" if current == "near" else "near"
        before = saved["score"]
        assert before["near"] + before["far"] == sum(
            r["winner"] is not None for r in saved["rallies"]
        )
        corrected = client.patch(f"{url}/score", json={"rally_index": pending, "winner": target})
        assert corrected.status_code == 200
        reloaded = client.get(f"{url}/record").json()
        expected = {side: before[side] for side in ("near", "far")}
        expected[target] += 1
        if current is not None:
            expected[current] -= 1
        assert {side: reloaded["score"][side] for side in ("near", "far")} == expected
        assert client.post(f"{url}/score/undo").status_code == 200
        undone = client.get(f"{url}/record").json()
        assert undone["score"] == before
        assert undone["rallies"][pending]["winner"] == current
