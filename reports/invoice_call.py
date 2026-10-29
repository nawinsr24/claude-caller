"""Daily invoice-service report, spoken as a Claude Caller call.

Reuses the Easy Logs dashboard query (invoice_api.fetch_calls) so the numbers match the dashboard.
Run with the Easy Logs venv:
  ~/DENOVO/easy-logs/easy-logs-app/.venv/bin/python reports/invoice_call.py [--hours 24] [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EASY_LOGS = Path.home() / "DENOVO/easy-logs/easy-logs-app"
sys.path.insert(0, str(EASY_LOGS))

from es_client import build_client, load_config  # noqa: E402
from invoice_api import fetch_calls  # noqa: E402

CHUNK_HOURS = 4  # batch the range so the cluster never gets one huge query


def collect(hours: int):
    client = build_client(load_config(app_dir=str(EASY_LOGS)))
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    calls, cur = {}, start
    while cur < end:
        nxt = min(cur + timedelta(hours=CHUNK_HOURS), end)
        tf = {"range": {"@timestamp": {"gte": cur.isoformat(), "lt": nxt.isoformat()}}}
        for c in fetch_calls(client, tf)[0]:
            calls.setdefault(c.trace_id or f"{c.time}|{c.api_url}|{c.method}", c)
        cur = nxt
    return list(calls.values())


# Same scope and failure rule as the dashboard's default view (dashboard_page._prepare / _render_health).
SCOPE_GROUPS = {"public": ("Public API", "Health check"), "internal": ("Portal internal", "Health check"), "all": None}


def in_scope(c, scope: str) -> bool:
    groups = SCOPE_GROUPS[scope]
    return groups is None or c.group in groups


def is_failed(c) -> bool:
    return str(c.result).upper() == "FAILED"


def spoken(op: str) -> str:
    """'POST /invoice/cancelPaymentLinkJava' -> 'invoice cancel Payment Link Java' (reads better aloud)."""
    import re
    prefix = ""
    if op.startswith("Undocumented: "):
        prefix, op = "undocumented ", op[len("Undocumented: "):]
    path = op.split(" ", 1)[-1] if op.startswith(("GET ", "POST ", "PUT ", "DELETE ", "PATCH ")) else op
    words = re.sub(r"[/{}_.-]+", " ", path).strip()
    return prefix + (re.sub(r"(?<=[a-z])(?=[A-Z])", " ", words) or op)


def summarize(calls, hours: int) -> tuple[str, dict]:
    failed = [c for c in calls if is_failed(c)]
    s5 = sum(1 for c in failed if (c.status or 0) >= 500)
    s4 = sum(1 for c in failed if 400 <= (c.status or 0) < 500)
    s401 = sum(1 for c in calls if c.status == 401)
    inv_ops = ("Create invoice", "Update invoice", "Payment")
    inv_failed = Counter(c.operation for c in failed if c.operation in inv_ops)
    top = Counter(c.operation for c in failed).most_common(1)
    rate = (100 * len(failed) / len(calls)) if calls else 0.0
    m = {"hours": hours, "total": len(calls), "failed": len(failed), "rate": round(rate, 1), "5xx": s5, "4xx": s4, "401": s401,
         "invoice_failed": dict(inv_failed), "top_failing": top[0] if top else None}

    if not calls:
        return f"Good morning. Invoice public API report: no API calls in the last {hours} hours.", m
    parts = [f"Good morning. Invoice public API report for the last {hours} hours.",
             f"{len(calls)} API calls, {len(failed)} failed, that is {rate:.1f} percent."]
    if failed:
        parts.append(f"{s5} server errors and {s4} client errors." if s5 else f"All {s4} are client errors.")
        if s401:
            parts.append(f"{s401} of them are token errors.")
        inv = [f"{n} {op.lower()}" for op, n in inv_failed.most_common()]
        parts.append(("Failed invoice calls: " + ", ".join(inv) + ".") if inv else "No invoice create, update or payment failures.")
        op, n = top[0]
        parts.append(f"Top failing API is {spoken(op)}, with {n} failure{'s' if n != 1 else ''}.")
    parts.append("Server errors need a look." if s5 else "No server errors." if failed else "All good.")
    return " ".join(parts), m


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
    message, metrics = summarize([c for c in collect(a.hours) if in_scope(c, a.scope)], a.hours)
    print(json.dumps(metrics))
    print(message)
    if not a.dry_run:
        print("call_id", call(message))


if __name__ == "__main__":
    main()
