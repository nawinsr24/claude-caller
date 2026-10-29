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
- `.github/workflows/build.yml` — GitHub Actions builds the APK (no local Android SDK needed), same
  as TamilTV. The APK is public and contains **no** personal settings.
- `docs/` — GitHub Pages: `index.html` (download page) and `pair.html` (QR pairing). Pairing settings travel
  in the URL fragment, which browsers never send to the server.

## Status
- [x] MCP server built and registered (`claude mcp list` → claude-caller ✔ Connected)
- [x] Android app written; `flutter analyze` clean, tests pass
- [x] Public repo + GitHub Pages download page; APK released by Actions
- [ ] Phone paired with the QR (ask Claude: "show my Claude Caller pairing QR")
- [ ] APK installed on the phone, *Start listening* tapped
- [ ] Test call

## Notes
- Messages pass through the public ntfy.sh server (topic names are the only secret). To avoid that,
  self-host ntfy and change `server` in `config.json`.
- Claude can only place a call while a session is running; for unattended alerts, a scheduled job
  can POST to the same topic.

## Install on the phone
1. On the phone open **https://nawinsr24.github.io/claude-caller/** → *Download for Android* → install
   (allow "install unknown apps").
2. Ask Claude *"show my Claude Caller pairing QR"* (MCP tool `pairing_qr`), scan it with the phone camera,
   tap **Open in Claude Caller**.
3. Tap **Start listening for calls** → allow notifications, full-screen calls and "ignore battery
   optimisation". Tap **Test the call screen and voice** to hear it.
4. Ask Claude: *"call me and tell me …"*.

New version: tag and push (`git tag v1.0.1 && git push --tags`); the download button always gets the latest.

Each CI build signs with a fresh debug key, so updating may require uninstalling the old version first.
