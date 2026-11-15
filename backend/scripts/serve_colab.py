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
import threading
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


TUNNEL_URL = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")


def tunnel_url(line: str) -> str | None:
    """The public URL in one line of cloudflared's log, if the line announces it."""
    match = TUNNEL_URL.search(line)
    return match.group(0) if match else None


def token_problem(token: str) -> str | None:
    """Why this token must not guard a public tunnel, or None when it is acceptable."""
    if token.strip().lower() in {"change-me", "changeme"}:
        return "set your own token: 'change-me' is the placeholder everyone knows"
    if len(token.strip()) < 8:
        return "the token must be at least 8 characters: the tunnel URL is public"
    return None


def _drain(stream) -> None:
    for _line in stream:
        pass


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token", required=True, help="bearer token the app must send")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    problem = token_problem(args.token)
    if problem:
        raise SystemExit(problem)

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
            url = tunnel_url(line)
            if url:
                print(f"\nShuttleSense API: {url}\nToken: {args.token}\n", flush=True)
                break
        # Keep reading cloudflared's log: a full, unread pipe would stall the tunnel.
        threading.Thread(target=_drain, args=(tunnel.stderr,), daemon=True).start()
        while server.poll() is None and tunnel.poll() is None:
            time.sleep(5)
    finally:
        tunnel.terminate()
        server.terminate()


if __name__ == "__main__":
    main()
