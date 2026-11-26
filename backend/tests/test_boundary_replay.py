from test_live import START, _send_frames, _wait_done, make_client

from shuttlesense.referee import run
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
        for call in live_calls:
            index = call["rally_index"]
            assert offline.line_calls[index].uncertain == call["uncertain"]
            winner = saved["rallies"][index]["winner"]
            assert offline.rallies[index].winner == winner
            assert (winner is None) == call["uncertain"]
        pending = next(c["rally_index"] for c in live_calls if c["uncertain"])
        before = saved["score"]
        assert before["near"] + before["far"] == sum(
            r["winner"] is not None for r in saved["rallies"]
        )
        corrected = client.patch(f"{url}/score", json={"rally_index": pending, "winner": "near"})
        assert corrected.status_code == 200
        reloaded = client.get(f"{url}/record").json()
        assert reloaded["score"]["near"] == before["near"] + 1
        assert reloaded["score"]["far"] == before["far"]
        assert client.post(f"{url}/score/undo").status_code == 200
        undone = client.get(f"{url}/record").json()
        assert undone["score"] == before
        assert undone["rallies"][pending]["winner"] is None
