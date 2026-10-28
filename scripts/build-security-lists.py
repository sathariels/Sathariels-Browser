#!/usr/bin/env python3
"""Build the bundled WebKit filter chunks and the local threat-hash snapshot.

The app repeats this conversion in Swift when it refreshes the lists. Keep the
two implementations on the same rule subset.
"""

import hashlib
import json
import struct
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Lumen" / "Resources"
CHUNK = 140_000
RESOURCE = {
    "script": "script",
    "image": "image",
    "stylesheet": "style-sheet",
    "font": "font",
    "media": "media",
    "xmlhttprequest": "raw",
    "other": "raw",
    "subdocument": "document",
    "document": "document",
    "popup": "popup",
    "svg": "svg-document",
}
ALLOWED = set(RESOURCE) | {"third-party", "first-party", "match-case", "important", "domain"}
ACCOUNT_EXCEPTION = {
    "trigger": {
        "url-filter": "^https?://",
        "if-domain": ["*accounts.google.com", "*myaccount.google.com", "*accounts.youtube.com"],
    },
    "action": {"type": "ignore-previous-rules"},
}


def hash64(value: str) -> int:
    return int.from_bytes(hashlib.sha256(value.encode("utf-8")).digest()[:8], "big")


def escape_regex(text: str) -> str:
    return "".join("\\" + ch if ch in r".\+?^${}()|[]" else ch for ch in text)


def url_filter(pattern: str) -> str | None:
    anchored = False
    if pattern.startswith("||"):
        anchored = True
        pattern = pattern[2:]
    elif pattern.startswith("|"):
        pattern = pattern[1:]
    if pattern.endswith("|"):
        pattern = pattern[:-1]
    pattern = pattern.rstrip("^")
    if not pattern or "*" in pattern or "/" in pattern[:2]:
        return None
    host, _, path = pattern.partition("/")
    host = host.lower()
    if not host or any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789.-" for ch in host):
        return None
    if host.startswith(".") or host.endswith(".") or ".." in host:
        return None
    escaped_host = escape_regex(host)
    if anchored and not path:
        return f"^https?://([^/?#]*\\.)?{escaped_host}[:/?#]"
    if anchored and path:
        escaped_path = escape_regex(path)
        return f"^https?://([^/?#]*\\.)?{escaped_host}/{escaped_path}"
    if path:
        return None
    escaped = escape_regex(pattern)
    if len(escaped) < 4:
        return None
    return escaped


def selector_ok(selector: str) -> bool:
    if not selector or len(selector) > 180:
        return False
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_#.- ,")
    return all(ch in allowed for ch in selector)


def parse_options(raw: str) -> dict | None:
    trigger: dict = {}
    types = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        if part.startswith("domain="):
            domains = [item for item in part[7:].split("|") if item]
            include = []
            exclude = []
            for domain in domains:
                negated = domain.startswith("~")
                host = domain[1:] if negated else domain
                host = host.lower()
                if not host or any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789.-" for ch in host):
                    return None
                (exclude if negated else include).append("*" + host)
            if include:
                trigger["if-domain"] = include
            if exclude:
                trigger["unless-domain"] = exclude
            continue
        name = part[1:] if part.startswith("~") else part
        if name not in ALLOWED and not part.startswith("~"):
            return None
        if part.startswith("~"):
            if part == "~third-party":
                trigger["load-type"] = ["first-party"]
            else:
                return None
            continue
        if part == "third-party":
            trigger["load-type"] = ["third-party"]
        elif part == "first-party":
            trigger["load-type"] = ["first-party"]
        elif part == "match-case":
            trigger["url-filter-is-case-sensitive"] = True
        elif part == "important":
            continue
        elif part in RESOURCE:
            types.append(RESOURCE[part])
        else:
            return None
    if types:
        trigger["resource-type"] = types
    return trigger


def network_rule(line: str) -> dict | None:
    exception = line.startswith("@@")
    body = line[2:] if exception else line
    pattern, _, options = body.partition("$")
    pattern = pattern.strip()
    trigger_extra = {}
    if options:
        parsed = parse_options(options)
        if parsed is None:
            return None
        trigger_extra = parsed
    regex = url_filter(pattern)
    if not regex or len(regex) > 500:
        return None
    trigger = {"url-filter": regex, "url-filter-is-case-sensitive": False}
    trigger.update(trigger_extra)
    action = {"type": "ignore-previous-rules"} if exception else {"type": "block"}
    return {"trigger": trigger, "action": action}


def cosmetic_rule(line: str) -> dict | None:
    if "#@#" in line or "#?#" in line or "#$#" in line:
        return None
    domains, separator, selector = line.partition("##")
    if separator != "##":
        return None
    selector = selector.strip()
    if not selector_ok(selector):
        return None
    trigger = {"url-filter": ".*"}
    if domains:
        if domains.startswith("~"):
            return None
        include = []
        for domain in domains.split(","):
            host = domain.strip().lower()
            if not host or host.startswith("~"):
                return None
            if any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789.-" for ch in host):
                return None
            include.append("*" + host)
        if not include:
            return None
        trigger["if-domain"] = include
    return {"trigger": trigger, "action": {"type": "css-display-none", "selector": selector}}


def convert_lines(lines) -> list[dict]:
    blocks = []
    exceptions = []
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("!") or line.startswith("[") or line.startswith("# "):
            continue
        if "##" in line or "#@#" in line or "#?#" in line:
            rule = cosmetic_rule(line)
            if rule:
                blocks.append(rule)
            continue
        rule = network_rule(line)
        if not rule:
            continue
        if rule["action"]["type"] == "ignore-previous-rules":
            exceptions.append(rule)
        else:
            blocks.append(rule)
    return blocks, exceptions


def write_chunks(rules, exceptions, directory: Path) -> int:
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob("blocker-*.json"):
        old.unlink()
    total = 0
    index = 0
    batch = []
    def flush():
        nonlocal index, batch
        if not batch and not exceptions:
            return
        payload = batch + exceptions + [ACCOUNT_EXCEPTION]
        path = directory / f"blocker-{index}.json"
        path.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
        index += 1
        batch = []
    for rule in rules:
        batch.append(rule)
        total += 1
        if len(batch) + len(exceptions) + 1 >= CHUNK:
            flush()
    if batch or exceptions:
        flush()
    return total


def threat_hashes(host_file: Path, phish_file: Path, dest: Path) -> int:
    values = set()
    for line in host_file.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        host = parts[-1].lower().strip(".")
        if host and host != "0.0.0.0":
            values.add(hash64(host))
    for line in phish_file.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = urllib.parse.urlsplit(line)
        host = (parts.hostname or "").lower().strip(".")
        if host:
            values.add(hash64(host))
        normalized = normalize_url(line)
        if normalized:
            values.add(hash64(normalized))
    ordered = sorted(values)
    dest.write_bytes(b"".join(struct.pack("<Q", item) for item in ordered))
    return len(ordered)


def normalize_url(url: str) -> str | None:
    parts = urllib.parse.urlsplit(url.strip())
    host = (parts.hostname or "").lower().strip(".")
    scheme = parts.scheme.lower()
    if scheme not in {"http", "https"} or not host:
        return None
    path = parts.path or "/"
    query = f"?{parts.query}" if parts.query else ""
    return f"{scheme}://{host}{path}{query}"


def main() -> None:
    sources = [Path("/tmp/filters/easylist.txt"), Path("/tmp/filters/easyprivacy.txt")]
    blocks = []
    exceptions = []
    for source in sources:
        file_blocks, file_exceptions = convert_lines(source.read_text(encoding="utf-8", errors="replace").splitlines())
        blocks.extend(file_blocks)
        exceptions.extend(file_exceptions)
    count = write_chunks(blocks, exceptions, OUT / "filters")
    hosts = Path("/tmp/filters/urlhaus-hosts.txt")
    phish = Path("/tmp/filters/openphish.txt")
    threats = threat_hashes(hosts, phish, OUT / "threat-hashes.bin")
    print(f"rules={count} exceptions={len(exceptions)} threats={threats}")


if __name__ == "__main__":
    main()
