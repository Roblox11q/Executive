#!/usr/bin/env python3
"""
Run user bot + staff bot on a single Render Web Service.

- User bot (bot.py): buyer commands + /api/status HTTP on PORT
- Staff bot (staff_bot.py): moderation, tickets, verification

Requires BOTH tokens in env:
  DISCORD_TOKEN        -> user bot
  STAFF_DISCORD_TOKEN  -> staff bot (must be a different Discord application)
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def _spawn(script: str, extra_env: dict | None = None) -> subprocess.Popen:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    return subprocess.Popen(
        [sys.executable, str(ROOT / script)],
        cwd=str(ROOT),
        env=env,
        stdout=sys.stdout,
        stderr=sys.stderr,
    )


def main() -> None:
    user_token = (os.getenv("DISCORD_TOKEN") or "").strip()
    staff_token = (os.getenv("STAFF_DISCORD_TOKEN") or "").strip()

    if not user_token:
        raise SystemExit("DISCORD_TOKEN is required for the user bot")
    if not staff_token:
        raise SystemExit(
            "STAFF_DISCORD_TOKEN is required for the staff bot.\n"
            "Create a second Discord application and set its token."
        )
    if user_token == staff_token:
        raise SystemExit(
            "DISCORD_TOKEN and STAFF_DISCORD_TOKEN must be different.\n"
            "One token cannot power two gateway sessions."
        )

    print("=" * 60)
    print("Executive Stand — combined launcher")
    print(f"  user bot  : bot.py   (token len={len(user_token)})")
    print(f"  staff bot : staff_bot.py (token len={len(staff_token)})")
    print("=" * 60)

    # Staff must not bind PORT; user bot serves /api/status for loaders
    user_proc = _spawn("bot.py")
    staff_proc = _spawn("staff_bot.py", {"COMBINED_SERVICE": "1"})

    procs = {"user": user_proc, "staff": staff_proc}

    def shutdown(signum=None, frame=None):
        print(f"[main] shutting down (signal={signum})")
        for name, p in procs.items():
            if p.poll() is None:
                print(f"[main] terminating {name} pid={p.pid}")
                p.terminate()
        deadline = time.time() + 10
        for name, p in procs.items():
            while p.poll() is None and time.time() < deadline:
                time.sleep(0.2)
            if p.poll() is None:
                print(f"[main] killing {name} pid={p.pid}")
                p.kill()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Keep the parent alive; if either child dies, restart it (Render free can flake)
    restart_counts = {"user": 0, "staff": 0}
    max_restarts = 20

    while True:
        time.sleep(3)
        for name, script in (("user", "bot.py"), ("staff", "staff_bot.py")):
            p = procs[name]
            code = p.poll()
            if code is None:
                continue
            restart_counts[name] += 1
            print(
                f"[main] {name} bot exited code={code} "
                f"(restart {restart_counts[name]}/{max_restarts})"
            )
            if restart_counts[name] > max_restarts:
                print(f"[main] {name} bot restarted too many times — exiting")
                shutdown()
            extra = {"COMBINED_SERVICE": "1"} if name == "staff" else None
            time.sleep(2)
            procs[name] = _spawn(script, extra)


if __name__ == "__main__":
    main()
