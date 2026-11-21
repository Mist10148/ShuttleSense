"""Run from backend/. Only the original nine legacy blobs have a format exemption."""

import subprocess
from pathlib import Path

BASELINE = {
    "scripts/bench_render_export.py": "59f653fff03f070054d87eac3235c01fb752c609",
    "scripts/bench_tracknet_single_batch.py": "91d6d957515260177c48c747f75049a6034e5e80",
    "scripts/bench_watch_coordination.py": "b7b4da32c141531793d855fff1bdc4eec8c58302",
    "scripts/bench_watch_tracknet_ceiling.py": "54cbaf4f06435992a5ee34d35716e3e10a9c44c4",
    "scripts/profile_watch_cuda_trace.py": "c2b8df230afdaa689c3cd236e5e54d49a7b16770",
    "scripts/profile_watch_pipeline.py": "18b84b42ba0b39d7cea307ac32379d4c81a007fe",
    "scripts/summarize_watch_cuda_trace.py": "332e6d5e338e8eedfa66e259e368ab401e1d0b27",
    "scripts/summarize_watch_gpu_timeline.py": "4cb923934a0cb2d4976c230ff2c376dca3826bfd",
    "tests/test_watch_cuda_trace_summary.py": "c4c7939209b3171ea18c783a5d6f93dfaf06380f",
}


def main() -> int:
    args = ["ruff", "format", "--check"]
    for name, expected in BASELINE.items():
        if Path(name).is_file():
            blob = subprocess.check_output(["git", "hash-object", name], text=True).strip()
            if blob == expected:
                args.extend(["--extend-exclude", name])
    return subprocess.call([*args, "."])


if __name__ == "__main__":
    raise SystemExit(main())
