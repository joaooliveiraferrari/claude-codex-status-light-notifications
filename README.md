# Agent Status Lights

Local "agent status lighting" for **Claude Code** and **Codex CLI** on Windows.
When an agent starts working, needs your approval, finishes, or errors out, your
keyboard RGB (via **OpenRGB**) changes color. If OpenRGB isn't available it falls
back to a **console message + Windows notification + sound** — so it always works.

Built for: Windows PowerShell (often inside the VS Code terminal), Anne Pro 2 keyboard.

**Portable by design:** clone it anywhere. Every script resolves its own location
(`$PSScriptRoot`) and the installer writes *your* machine's absolute path into the hooks,
so there are no hard-coded paths to edit. The core logic lives in one reusable module
(`lib/StatusLights.psm1`); the scripts and UI are thin entry points over it.

---

## Get it / prerequisites

```powershell
git clone https://github.com/<you>/claude-codex-status-light-notifications.git
cd claude-codex-status-light-notifications
```

| Requirement | Needed for | If missing |
|---|---|---|
| Windows + PowerShell 5.1+ | everything | (built in) |
| **Node.js** (any recent) | the dashboard UI | falls back to a pure-PowerShell server |
| **OpenRGB** (`openrgb.org` / `scoop install openrgb`) | real RGB control | falls back to console + notification + sound |
| **Claude Code** and/or **Codex CLI** | auto status from agents | you can still drive it manually / via the UI |

Nothing is installed globally and no npm packages are pulled (the UI server uses Node core
only). No admin rights required.

---

## Color meanings

| Status | Meaning | Default color |
|---|---|---|
| **working** | Agent started / turn in progress | Brand blue `#0982FC` |
| **approval** | Needs permission / your input | Orange `#FC682A` |
| **done** | Finished successfully | Green `#00FF00` |
| **error** | Failed task | Purple `#8D3EF9` |
| **idle / normal** | Ready / nothing happening | White `#FEFEFF` |
| **off** | Lights off | Black `#000000` |

> Alternatives from the brief (red `#FF0000` for working, red-blink for error) are in
> `config/status-light.config.json` under `altColors` — copy one into `colors` to use it.

---

## Quick start

```powershell
cd C:\Dev\agent-status-lights

# 1. See it work (cycles every status; no config changes)
./test-status.ps1

# 2. Open the dashboard
./start-ui.ps1            # http://localhost:8787

# 3. Install agent hooks (backs up configs, asks nothing destructive)
./install.ps1 -Plan      # dry-run: shows exactly what changes
./install.ps1            # actually merge hooks into Claude + Codex
```

Everything exits `0` and never throws, so a hook can **never** break Claude or Codex.

---

## Running the test

```powershell
./test-status.ps1                 # full visual cycle + multi-session demo
./test-status.ps1 -NoCycle        # diagnostics only (OpenRGB present? device detected?)
./test-status.ps1 -DelaySeconds 1 # faster
```

It prints whether OpenRGB is installed, whether your Anne Pro 2 is detected, and which
provider (openrgb / fallback) is in use, then walks through every color and simulates two
concurrent sessions.

---

## Starting the UI

```powershell
./start-ui.ps1            # prefers Node (ui/server.js, zero deps), opens the browser
./start-ui.ps1 -NoBrowser
```

The dashboard (`http://localhost:8787`, localhost-only) shows current status, provider,
detected devices, and recent hook events. Buttons: **Working / Approval / Done / Error /
Normal / Off / Run full test / Install hooks / Uninstall hooks**. Editable config: OpenRGB
path, device index, device name, allowAllDevices, all status colors, notifications, sounds —
**Save config** writes back to `config/status-light.config.json` (with a backup).

If Node is ever missing, it automatically falls back to the pure-PowerShell server
(`ui/server.ps1`).

---

## Changing colors

- **UI:** edit the color pickers under *Configuration → Status colors*, click **Save config**.
- **File:** edit `config/status-light.config.json` → `colors`. Use `#RRGGBB`.

```json
"colors": {
  "working": "#0982FC",
  "approval": "#FC682A",
  "done": "#00FF00",
  "error": "#8D3EF9",
  "idle": "#FEFEFF",
  "normal": "#FEFEFF",
  "off": "#000000"
}
```

---

## Notifications, sounds & turning the keyboard lights off

Each status can drive three independent outputs: the **keyboard color**, a **Windows
notification**, and a **sound**. Toggle each in `config/status-light.config.json`:

```json
"enableOpenRgb": true,                              // master switch for keyboard color
"enableNotifications": true,                        // Windows toast notifications
"notifyOnStatuses": ["working","approval","done","error"],  // which statuses notify
"enableSounds": true,                               // play a sound
"soundOnStatuses": ["approval","error"]            // which statuses play a sound
```

- **`enableOpenRgb: false`** disables *all* keyboard color changes — OpenRGB is never
  called. Use this if you want **notifications only** (e.g. no RGB keyboard, or you just
  don't want the lights). The provider reports as `disabled`.
- **`notifyOnStatuses`** picks exactly which statuses raise a toast. For example, to be
  notified only when an agent **finishes** or **needs you**, use `["approval","done","error"]`
  — that drops the per-turn "working" toast.
- **`enableNotifications: false`** silences all toasts regardless of `notifyOnStatuses`;
  **`enableSounds: false`** silences all sounds.

> The `done` notification fires from the **Stop** hook, i.e. the moment the agent finishes a
> turn — so "notify me only when Claude is done" is just `enableOpenRgb: false` +
> `notifyOnStatuses` containing `done`.

---

## Configuring the OpenRGB device (index / name)

OpenRGB is **not bundled**. Install it from <https://openrgb.org/> (or `scoop install openrgb`),
then point this tool at your keyboard. There are three selection modes, in priority order:

1. **By index** — set `deviceIndex` to a number ≥ 0 (fastest, most reliable).
   Find indices with: `OpenRGB.exe --list-devices` (or the UI → *RGB Provider → Rescan*).
2. **By name** — leave `deviceIndex: -1` and set `deviceName` (e.g. `"Anne Pro 2"`);
   the tool resolves the index by matching the name.
3. **All devices** — set `allowAllDevices: true`. **Safety:** if no index/name matches and
   `allowAllDevices` is `false`, the tool refuses to touch *every* device and uses fallbacks
   instead (so it never randomly lights up unrelated hardware).

```json
"openRgbPath": "",          // empty = auto-detect on PATH / common locations
"deviceIndex": -1,          // 0,1,2… to target a specific device
"deviceName": "Anne Pro 2",
"allowAllDevices": false
```

OpenRGB CLI used: `OpenRGB.exe [--device <i>] --mode static --color RRGGBB`, run with an
8s timeout so a hung call can never block your agent.

---

## Claude Code setup

Claude reads hooks from `~/.claude/settings.json`. The installer **merges** (never replaces)
and **backs up first** (to `./backups`). Mapped events:

| Claude hook | Status |
|---|---|
| `SessionStart` | idle |
| `UserPromptSubmit` (turn start) | working |
| `Notification` (permission / waiting for input) | approval |
| `Stop` (turn done) | done |

```powershell
./install.ps1 -Target claude -Plan   # preview
./install.ps1 -Target claude         # apply
```

Then **in Claude Code run `/hooks`** to confirm they're registered.

> **Limitation:** Claude Code has **no dedicated "error" hook event**, so a *failed* task
> won't auto-turn purple from Claude. Drive `error` manually (UI button or
> `./status-light.ps1 -Status error`). Everything else is automatic.

---

## Codex CLI setup

Verified against **codex-cli 0.141.0**, which has a real Claude-Code-style hook system.
The installer writes `~/.codex/hooks.json` and points `~/.codex/config.toml` at it
(`hooks = "hooks.json"`), backing up anything that exists. Mapped events (from the actual
Codex event enum: `PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact,
SessionStart, UserPromptSubmit, SubagentStart, SubagentStop, Stop`):

| Codex hook | Status |
|---|---|
| `SessionStart` | idle |
| `UserPromptSubmit` | working |
| `PermissionRequest` | approval |
| `Stop` | done |

```powershell
./install.ps1 -Target codex -Plan    # preview
./install.ps1 -Target codex          # apply
```

**Trusting hooks (required):** Codex sandboxes hooks. After install, **run `codex` once** —
on startup it shows *"Hooks need review"*; review and **trust** them (they run outside the
sandbox once trusted). Verify your install health with `codex doctor`. Do **not** use
`--dangerously-bypass-hook-trust` unless you fully understand it.

> **Limitation:** Codex (like Claude) has **no dedicated "error" event**, so `error` is
> manual/UI-driven. `PermissionRequest` hooks currently "fail closed" by design — ours only
> *sets a light* and always exits 0, so it never blocks an approval.

---

## Why ObinsKit may not automate this

ObinsKit (the Anne Pro 2's official app) is **GUI-only**. It has no documented command-line
interface or watched config file you can script from PowerShell, and it talks to the keyboard
over its own USB/Bluetooth protocol. So there's no reliable, supported way for a hook to tell
ObinsKit "turn orange now." **OpenRGB** is the right tool: it exposes a real CLI
(`OpenRGB.exe --device … --mode static --color …`) and an SDK server, which is exactly what
automation needs. If you ever find a real ObinsKit CLI, you can add it as another provider in
`status-light.ps1`.

---

## Multiple concurrent sessions

State lives in `%TEMP%\agent-status-lights\state.json`, guarded by a named mutex. Each agent
session is tracked separately and the **effective** color is the highest-priority active
status:

```
approval (5) > working (4) > error (3) > done (2) > idle (1)
```

Consequences (by design):
- **One session finishing while another still works → stays working, does NOT turn green.**
- **Approval turns orange immediately** and stays orange until that session's next
  working/done/error event (approval outranks working).
- `off` clears all sessions and turns the light black.
- Stale sessions are pruned (`sessionMaxAgeMinutes`, default 180); `done` sessions expire to
  idle after `doneExpireMinutes` (default 30). No background loops, no busy-waiting.

---

## Troubleshooting

**VS Code terminal has a stale PATH** (e.g. you just installed OpenRGB/Node and it's "not
found"): VS Code caches the environment when it launches. Fully **restart VS Code** (not just
the terminal), or run the tool from a fresh external PowerShell. Check with
`Get-Command OpenRGB`.

**OpenRGB doesn't detect the keyboard:**
- Run `OpenRGB.exe --list-devices`. Anne Pro 2 must appear. If not, open the OpenRGB GUI once,
  enable it, and make sure the **SDK Server** is running (Settings → enable server).
- Close **ObinsKit** and any other RGB app — only one program can own the keyboard at a time.
- Some Anne Pro 2 firmware/USB modes aren't detected; try a different USB port/cable, or run
  OpenRGB once as admin to install its device support, then normally.
- Until it's detected, the tool stays in fallback mode (you'll still get notifications/sounds).

**Hooks not firing:**
- Claude: run `/hooks` to confirm registration; check `~/.claude/settings.json`.
- Codex: ensure you **trusted** the hooks on `codex` startup; run `codex doctor`; confirm
  `~/.codex/config.toml` has `hooks = "hooks.json"` and `~/.codex/hooks.json` exists.
- Check the log: `%TEMP%\agent-status-lights\status-light.log`.
- Test the command directly:
  `powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Dev\agent-status-lights\status-light.ps1" -Status working`

**PowerShell execution policy** blocks scripts: all entry points are invoked with
`-ExecutionPolicy Bypass`, so you normally don't need to change anything. If you run a script
directly and it's blocked, use:
`powershell -ExecutionPolicy Bypass -File .\test-status.ps1` (no admin needed).

**Multiple sessions stuck on a color:** delete the state file to reset —
`Remove-Item "$env:TEMP\agent-status-lights\state.json"` — then set any status again.

**UI port in use / won't start:** change `serverPort` in the config, or use the Node server
(`start-ui.ps1`). The PowerShell server binds `http://localhost:<port>/` which needs no admin
for localhost.

---

## Files

```
agent-status-lights/
├─ README.md  LICENSE  package.json  .gitignore
├─ install.ps1            # merge hooks into Claude/Codex (backup + idempotent; -Plan dry-run)
├─ uninstall.ps1          # remove only our hooks
├─ status-light.ps1       # CLI entry: -Status working|approval|done|error|idle|normal|off
├─ test-status.ps1        # diagnostics + visual cycle + multi-session demo
├─ start-ui.ps1           # launch dashboard (Node, PowerShell fallback)
├─ lib/
│  └─ StatusLights.psm1   # reusable core: config, providers, fallbacks, state, sessions
├─ config/
│  └─ status-light.config.json
├─ examples/
│  ├─ claude-hooks.example.json
│  └─ codex-hooks.example.json
├─ ui/
│  ├─ index.html  app.js  styles.css
│  ├─ server.js          # zero-dependency Node server (primary)
│  └─ server.ps1         # pure-PowerShell HttpListener fallback
└─ backups/              # timestamped backups of any config we edit
```

### Extending (add your own provider)

All RGB/fallback logic is in `lib/StatusLights.psm1`. To add a provider (e.g. Razer, a
different keyboard, an MQTT light), add a `Set-Sl<Yours>` function that returns `'<name>'`
on success or `'fallback'`, then call it from `Set-AgentStatus` before/after `Set-SlOpenRgb`.
Entry scripts and the UI need no changes — they only call `Set-AgentStatus`.

## Uninstall

```powershell
./uninstall.ps1 -Plan    # preview
./uninstall.ps1          # remove our hooks from Claude + Codex (keeps everything else)
```

Original configs are also preserved as timestamped copies in `./backups`.
