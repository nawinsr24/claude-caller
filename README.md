# Claude Caller

Ask Claude "call me" and your phone rings like an incoming call; when you answer, the message is read
aloud. Free: calls are relayed through [ntfy](https://ntfy.sh) on private random topics.

```
Claude ──place_call──▶ MCP server ──HTTP──▶ ntfy.sh/<call_topic> ──▶ Android app (rings, speaks)
Claude ◀─wait_for_reply─ MCP server ◀──── ntfy.sh/<reply_topic> ◀── Got it / Repeat / voice reply
```

## Parts
- `mcp/server.py` — MCP server (registered in Claude Code as `claude-caller`, user scope).
  Tools: `place_call`, `wait_for_reply`, `get_call_replies`, `caller_setup_info`.
- `config.json` — ntfy server + the two private topic names (created on first run, mode 600).
  Anyone who knows the call topic can ring you, so keep it private.
- `app/` — Android app (Flutter): full-screen incoming-call screen, text-to-speech, replies.
- `.github/workflows/build.yml` — GitHub Actions builds the APK (no local Android SDK needed),
  same as TamilTV. Topics are injected from repo secrets `CALL_TOPIC` / `REPLY_TOPIC`.

## Status
- [x] MCP server built and registered (`claude mcp list` → claude-caller ✔ Connected)
- [x] Android app written; `flutter analyze` clean, tests pass
- [ ] Private GitHub repo + secrets, APK built by Actions
- [ ] APK installed on the phone, *Start listening* tapped
- [ ] Test call

## Until the app is ready
Install the free **ntfy** app from the Play Store and subscribe to the `call_topic` from `config.json`
(set notifications to *max priority*). Calls arrive as urgent notifications — no voice yet.

## Notes
- Messages pass through the public ntfy.sh server (topic names are the only secret). To avoid that,
  self-host ntfy and change `server` in `config.json`.
- Claude can only place a call while a session is running; for unattended alerts, a scheduled job
  can POST to the same topic.

## Install on the phone
1. GitHub → repo → **Actions** → latest run → *Artifacts* → `ClaudeCaller-android` (or tag `v1.0.0` for a Release).
2. Open the APK on the phone (allow "install unknown apps").
3. Open Claude Caller → **Start listening for calls** → allow notifications, full-screen calls and
   "ignore battery optimisation". Tap **Test the call screen and voice** to hear it.
4. Ask Claude: *"call me and tell me …"*.

Each CI build signs with a fresh debug key, so updating may require uninstalling the old version first.
