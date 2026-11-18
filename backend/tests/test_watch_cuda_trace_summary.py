import json
import sys

from test_eval_scripts import load_script


def test_trace_summary_correlates_nested_launch_and_leaves_other_copies_unattributed(
    tmp_path, monkeypatch, capsys
):
    summarize = load_script("summarize_watch_cuda_trace")
    trace = tmp_path / "trace.json"
    ranges = tmp_path / "ranges.json"
    trace.write_text(json.dumps({"traceEvents": [
        {"name": "watch_clock_anchor", "ph": "X", "ts": 1000},
        {"cat": "cuda_runtime", "tid": 7, "ts": 1015, "name": "cudaStreamSynchronize",
         "dur": 2, "args": {"correlation": 42}},
        {"cat": "cuda_runtime", "tid": 7, "ts": 1016, "name": "cudaLaunchKernel"},
        {"cat": "gpu_memcpy", "name": "HtoD", "dur": 8, "args": {"correlation": 42}},
        {"cat": "gpu_memcpy", "name": "DtoH", "dur": 3, "args": {"correlation": 77}},
        {"cat": "kernel", "dur": 4},
    ]}), encoding="utf8")
    ranges.write_text(json.dumps({"anchor_ns": 100000, "ranges": [
        {"name": "players", "tid": 7, "start_ns": 100000, "end_ns": 140000},
        {"name": "pose", "tid": 7, "start_ns": 110000, "end_ns": 120000},
    ]}), encoding="utf8")
    monkeypatch.setattr(sys, "argv", ["summary", "--trace", str(trace), "--ranges", str(ranges)])
    summarize.main()
    result = json.loads(capsys.readouterr().out)
    assert result["activities_count_total_us"]["pose"]["HtoD"] == [1, 8]
    assert result["activities_count_total_us"]["unattributed"]["DtoH"] == [1, 3]
    assert result["activities_count_total_us"]["unattributed"]["kernel"] == [1, 4]
    assert result["sync_count_total_us"]["pose"] == [1, 2]
