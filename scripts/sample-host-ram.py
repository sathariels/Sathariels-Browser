#!/usr/bin/env python3
"""Sample app and WebKit RSS from outside the sandbox, or print a saved timeline."""

import subprocess
import sys
import time


def snapshot() -> tuple[int, int]:
    raw = subprocess.check_output(["ps", "-ax", "-o", "rss=,comm="], text=True, errors="replace")
    app = web = 0
    for line in raw.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        try:
            rss = int(parts[0])
        except ValueError:
            continue
        comm = parts[1].lower()
        if "sathariels" in comm:
            app += rss
        elif "webkit" in comm or "webcontent" in comm:
            web += rss
    return app, web


def watch(path: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        while True:
            app, web = snapshot()
            handle.write(f"{time.time():.0f} app_kb={app} webkit_kb={web}\n")
            handle.flush()
            time.sleep(2)


def show(path: str) -> None:
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        print("No host RAM timeline.")
        return
    for index, line in enumerate(lines):
        if index % 5 and index != len(lines) - 1:
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        app = int(parts[1].split("=", 1)[1])
        web = int(parts[2].split("=", 1)[1])
        print(f"{parts[0]} app_mb={app // 1024} webkit_mb={web // 1024} total_mb={(app + web) // 1024}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--watch":
        watch(sys.argv[2])
    elif len(sys.argv) == 2:
        show(sys.argv[1])
    else:
        raise SystemExit("usage: sample-host-ram.py --watch FILE | FILE")
