"""Run the API in Colab behind a cloudflared quick tunnel (T1.7).

Usage (inside the Colab notebook): python scripts/serve_colab.py --token <secret>
Prints the public https URL to enter in the app's connect screen.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
CLOUDFLARED_URL = (
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
)


def ensure_cloudflared() -> Path:
    path = BACKEND_DIR / ".bin" / "cloudflared"
    if not path.exists():
        path.parent.mkdir(exist_ok=True)
        urllib.request.urlretrieve(CLOUDFLARED_URL, path)
        path.chmod(0o755)
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token", required=True, help="bearer token the app must send")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    env = {**os.environ, "SHUTTLESENSE_TOKEN": args.token}
    server = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "shuttlesense.api.main:app", "--port", str(args.port)],
        cwd=BACKEND_DIR,
        env=env,
    )
    tunnel = subprocess.Popen(
        [str(ensure_cloudflared()), "tunnel", "--url", f"http://localhost:{args.port}"],
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        for line in tunnel.stderr:
            match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", line)
            if match:
                print(f"\nShuttleSense API: {match.group(0)}\nToken: {args.token}\n", flush=True)
                break
        while server.poll() is None and tunnel.poll() is None:
            time.sleep(5)
    finally:
        tunnel.terminate()
        server.terminate()


if __name__ == "__main__":
    main()
