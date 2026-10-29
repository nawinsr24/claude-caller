"""Daily invoice-service report, spoken in casual Tamil as a Claude Caller call.

Reuses the Easy Logs dashboard query (invoice_api.fetch_calls) so the numbers match the dashboard.
Run with the Easy Logs venv:
  ~/DENOVO/easy-logs/easy-logs-app/.venv/bin/python reports/invoice_call.py [--hours 24] [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EASY_LOGS = Path.home() / "DENOVO/easy-logs/easy-logs-app"
sys.path.insert(0, str(EASY_LOGS))

from es_client import build_client, load_config  # noqa: E402
from invoice_api import INVOICE_FILES, _scan, fetch_calls, parse_pino_line  # noqa: E402

CHUNK_HOURS = 4  # batch the range so the cluster never gets one huge query

# Same scope and failure rule as the dashboard's default view (dashboard_page._prepare / _render_health).
SCOPE_GROUPS = {"public": ("Public API", "Health check"), "internal": ("Portal internal", "Health check"), "all": None}

# API families by path root, as they are spoken.
FAMILIES = [("customers", "கஸ்டமர் API"), ("invoices", "இன்வாய்ஸ் API")]
OTHER_FAMILY = "மத்த API"
NUM_WORDS = ["பூஜ்யம்", "ஒண்ணு", "ரெண்டு", "மூணு", "நாலு", "அஞ்சு", "ஆறு", "ஏழு", "எட்டு", "ஒம்பது", "பத்து"]
PAYMENT_PATH_RE = re.compile(r"^/invoices/([^/]+)/payment/?$")


def num(n: int) -> str:
    return NUM_WORDS[n] if 0 <= n < len(NUM_WORDS) else str(n)


def window(hours: int) -> tuple[datetime, datetime]:
    end = datetime.now(timezone.utc)
    return end - timedelta(hours=hours), end


def range_filter(gte: datetime, lt: datetime) -> dict:
    return {"range": {"@timestamp": {"gte": gte.isoformat(), "lt": lt.isoformat()}}}


def collect(client, start: datetime, end: datetime):
    calls, cur = {}, start
    while cur < end:
        nxt = min(cur + timedelta(hours=CHUNK_HOURS), end)
        for c in fetch_calls(client, range_filter(cur, nxt))[0]:
            calls.setdefault(c.trace_id or f"{c.time}|{c.api_url}|{c.method}", c)
        cur = nxt
    return list(calls.values())


def created_invoice_numbers(client, start: datetime, end: datetime, trace_ids: list[str]) -> set[str]:
    """Invoice numbers from successful create calls (their EXTERNAL_INVOICE log line carries invoice_number)."""
    found: set[str] = set()
    for i in range(0, len(trace_ids), 200):
        chunk = trace_ids[i:i + 200]
        query = {"bool": {
            "filter": [range_filter(start, end), {"terms": {"filename.keyword": INVOICE_FILES[:2]}},
                       {"match_phrase": {"log": "invoice_number"}}],
            "should": [{"match_phrase": {"log": t}} for t in chunk], "minimum_should_match": 1,
        }}
        for d in _scan(client, query, 5000):
            ev = parse_pino_line(d.get("log", "")) or {}
            msg = ev.get("message")
            try:
                msg = json.loads(msg) if isinstance(msg, str) else msg
            except json.JSONDecodeError:
                continue
            number = ((msg or {}).get("data") or {}).get("invoice_number") if isinstance(msg, dict) else None
            if number and ev.get("trace_id") in chunk:
                found.add(str(number))
    return found


def in_scope(c, scope: str) -> bool:
    groups = SCOPE_GROUPS[scope]
    return groups is None or c.group in groups


def is_failed(c) -> bool:
    return str(c.result).upper() == "FAILED"


def family(c) -> str:
    root = c.path.split("?", 1)[0].strip("/").split("/", 1)[0]
    return next((name for key, name in FAMILIES if root == key), OTHER_FAMILY)


def metrics(client, calls, start, end) -> dict:
    failed = [c for c in calls if is_failed(c)]
    fams: dict[str, dict] = {}
    for c in calls:
        f = fams.setdefault(family(c), {"calls": 0, "failed": Counter()})
        f["calls"] += 1
        if is_failed(c):
            f["failed"][c.status or 0] += 1

    creates = [c for c in calls if c.operation == "Create invoice" and not is_failed(c)]
    created = created_invoice_numbers(client, start, end, [c.trace_id for c in creates if c.trace_id])
    paid = {m.group(1) for c in calls if not is_failed(c) and c.operation == "Payment"
            and (m := PAYMENT_PATH_RE.match(c.path.split("?", 1)[0]))}
    return {
        "total": len(calls), "failed": len(failed),
        "5xx": sum(1 for c in failed if (c.status or 0) >= 500),
        "families": {k: {"calls": v["calls"], "failed": dict(v["failed"])} for k, v in fams.items()},
        # A create without a number in its logs still counts as created (pending unless we see its payment).
        "created": max(len(creates), len(created)),
        "completed": len(created & paid),
        "payments_total": len(paid),
    }


def tamil_message(m: dict, hours: int) -> str:
    """Short and casual: totals, which API group failed, invoice status, verdict."""
    when = "நேத்து" if hours == 24 else f"கடைசி {hours} மணி நேரத்துல"
    if not m["total"]:
        return f"குட் மார்னிங் நவீன்! {when} இன்வாய்ஸ் API-ல கால் எதுவும் வரல."
    parts = [f"குட் மார்னிங் நவீன்! {when} {m['total']} கால்ஸ்."]
    if m["failed"]:
        by_fam = [(name.replace(" API", ""), sum(f["failed"].values())) for name, f in m["families"].items() if f["failed"]]
        by_fam.sort(key=lambda kv: -kv[1])
        parts.append(f"{m['failed']} ஃபெயில், " + ", ".join(f"{n} {num(k)}" for n, k in by_fam) + ".")
    else:
        parts.append("எல்லாம் சக்சஸ்.")
    created, done = m["created"], m["completed"]
    if created:
        parts.append(f"{created} இன்வாய்ஸ் கிரியேட், {done} கம்ப்ளீட், {created - done} பெண்டிங்.")
    parts.append(f"{m['5xx']} சர்வர் எரர், கொஞ்சம் பாருங்க." if m["5xx"] else "சர்வர் எரர் இல்ல, சூப்பர்!")
    return " ".join(parts)


def call(message: str) -> str:
    cfg = json.loads((ROOT / "config.json").read_text())
    req = urllib.request.Request(f"{cfg['server']}/{cfg['call_topic']}", data=message.encode(), method="POST",
                                 headers={"Title": "Invoice report", "Priority": "5", "Tags": "telephone_receiver"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode()).get("id", "")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=int, default=24)
    ap.add_argument("--scope", choices=list(SCOPE_GROUPS), default="public")
    ap.add_argument("--dry-run", action="store_true", help="print the message, don't call")
    a = ap.parse_args()
    client = build_client(load_config(app_dir=str(EASY_LOGS)))
    start, end = window(a.hours)
    calls = [c for c in collect(client, start, end) if in_scope(c, a.scope)]
    m = metrics(client, calls, start, end)
    message = tamil_message(m, a.hours)
    print(json.dumps(m, ensure_ascii=False))
    print(message)
    if not a.dry_run:
        print("call_id", call(message))


if __name__ == "__main__":
    main()
