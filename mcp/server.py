"""Claude Caller MCP server: lets Claude "call" your phone and hear your reply.

Calls are relayed through ntfy (https://ntfy.sh, free) on a private random topic. The Claude Caller
Android app listens on that topic, rings like an incoming call, and reads the message aloud; your
answer (Got it / Repeat / a spoken reply) comes back on a second private topic.

Tools: place_call, wait_for_reply, get_call_replies, caller_setup_info.
"""

from __future__ import annotations

import json
import secrets
import time
import urllib.parse
import urllib.request
from pathlib import Path

from mcp.server.mcpserver import MCPServer

CONFIG_PATH = Path(__file__).resolve().parent.parent / "config.json"
DEFAULT_SERVER = "https://ntfy.sh"


def load_config() -> dict:
    """Create private topics on first use; keep them stable afterwards."""
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text())
    cfg = {
        "server": DEFAULT_SERVER,
        "call_topic": "cc-call-" + secrets.token_urlsafe(18).replace("_", "x").replace("-", "y"),
        "reply_topic": "cc-reply-" + secrets.token_urlsafe(18).replace("_", "x").replace("-", "y"),
    }
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    CONFIG_PATH.chmod(0o600)  # the topic names are the only secret
    return cfg


def _publish(cfg: dict, topic: str, body: str, headers: dict) -> dict:
    req = urllib.request.Request(f"{cfg['server']}/{topic}", data=body.encode(), method="POST",
                                 headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def _poll(cfg: dict, topic: str, since: str) -> list[dict]:
    url = f"{cfg['server']}/{topic}/json?poll=1&since={urllib.parse.quote(since)}"
    with urllib.request.urlopen(url, timeout=15) as resp:
        lines = resp.read().decode().splitlines()
    return [m for m in (json.loads(x) for x in lines if x.strip()) if m.get("event") == "message"]


def _parse_reply(m: dict) -> dict:
    try:
        data = json.loads(m.get("message", ""))
    except json.JSONDecodeError:
        data = {"action": "reply", "text": m.get("message", "")}
    return {"call_id": data.get("call_id"), "action": data.get("action"), "text": data.get("text", ""),
            "at": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(m.get("time", 0)))}


server = MCPServer(
    name="claude-caller",
    instructions=(
        "Use place_call only when the user explicitly asks you to call them, or asked to be called when "
        "something happens. Keep the message short and speakable (it is read aloud by text-to-speech). "
        "After placing a call, use wait_for_reply if you need their answer."
    ),
)


@server.tool()
def place_call(message: str, title: str = "Claude is calling", urgent: bool = True) -> dict:
    """Ring the user's phone (Claude Caller app) and read `message` aloud when they answer.

    Keep it under ~300 characters and phrased to be spoken. Returns the call id for wait_for_reply.
    """
    cfg = load_config()
    res = _publish(cfg, cfg["call_topic"], message.strip()[:1000], {
        "Title": title[:120],
        "Priority": "5" if urgent else "4",
        "Tags": "telephone_receiver",
    })
    return {"call_id": res.get("id"), "status": "ringing", "message": message.strip()[:1000]}


@server.tool()
def wait_for_reply(call_id: str, timeout_seconds: int = 120) -> dict:
    """Wait (polling) for the user's answer to a call: action 'ack', 'repeat', 'reply' (with spoken text)."""
    cfg = load_config()
    deadline = time.time() + max(5, min(timeout_seconds, 600))
    while time.time() < deadline:
        for m in _poll(cfg, cfg["reply_topic"], "15m"):
            reply = _parse_reply(m)
            if reply["call_id"] == call_id and reply["action"] in ("ack", "reply", "decline"):
                return {"status": "answered", **reply}
        time.sleep(3)
    return {"status": "no_answer", "call_id": call_id, "waited_seconds": timeout_seconds}


@server.tool()
def get_call_replies(since_minutes: int = 60) -> list[dict]:
    """List answers received from the phone in the last N minutes (newest last)."""
    cfg = load_config()
    return [_parse_reply(m) for m in _poll(cfg, cfg["reply_topic"], f"{max(1, since_minutes)}m")]


@server.tool()
def caller_setup_info() -> dict:
    """Pairing details for the Claude Caller app (server and topics)."""
    cfg = load_config()
    return {"server": cfg["server"], "call_topic": cfg["call_topic"], "reply_topic": cfg["reply_topic"],
            "config_file": str(CONFIG_PATH)}


if __name__ == "__main__":
    server.run("stdio")
