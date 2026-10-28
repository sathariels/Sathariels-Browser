#!/usr/bin/env python3
"""Print the exception and top frames from recent DiagnosticReports."""

import json
import sys
from pathlib import Path


def summarize(path: Path) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    start = text.find("{")
    payload = json.loads(text[start:] if start >= 0 else text)
    exc = payload.get("exception") or {}
    term = payload.get("termination") or {}
    print(path)
    print("exception", exc.get("type"), exc.get("signal"), exc.get("codes"))
    print("termination", term.get("indicator"), term.get("namespace"), term.get("reasons"))
    images = payload.get("usedImages") or []
    for thread in payload.get("threads") or []:
        if not thread.get("triggered"):
            continue
        print("triggered", thread.get("queue"), thread.get("name"))
        for frame in (thread.get("frames") or [])[:12]:
            image = frame.get("imageIndex")
            name = ""
            if isinstance(image, int) and image < len(images):
                name = (images[image] or {}).get("name", "")
            symbol = frame.get("symbol") or hex(frame.get("imageOffset") or 0)
            print(f"  {name} {symbol}")


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = sorted(path for path in root.iterdir() if path.is_file()) if root.is_dir() else [root]
    if not files:
        print("No crash reports.")
        return
    for path in files:
        try:
            summarize(path)
        except Exception as error:
            print(path, "unreadable", error)


if __name__ == "__main__":
    main()
