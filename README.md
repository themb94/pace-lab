# Pace Lab

A macOS app for planning and analysing your running training — with desktop
widgets, Garmin/Strava sync and an AI coach that runs on your own machine
through **Claude Code**, **Codex** or a **local model** (LM Studio).

> The user interface and the coach currently speak **German**.

- **Plan** — training blocks in a simple JSON file, every session with its
  structured workout (warm-up, intervals, pace targets). Tick sessions off,
  see planned vs. run kilometres per week.
- **Runs** — load new runs from **Garmin Connect** (directly, no AI involved)
  or **Strava** (through Claude Code). Splits, heart-rate zones, analysis.
- **Coach** — weekly review, adjusting a week, planning a whole new block. The
  coach edits your plan files; every change is versioned with git and can be
  undone. Garmin workouts are only created after your explicit approval.
- **Garmin** — send a week's workouts to your watch.
- **Widgets** — next session, week progress, last run.

Everything stays on your Mac: your training data lives in a folder you choose,
logins stay with Garmin, Strava and the CLIs you already use. Pace Lab has no
server, no account and no telemetry.

## Requirements

- macOS 26 or newer, Xcode 26 or newer
- An Apple developer team to sign the app (a free Personal Team from
  Xcode → Settings → Accounts should do)
- At least one coach:
  [Claude Code](https://docs.claude.com/en/docs/claude-code/setup),
  [Codex](https://developers.openai.com/codex/cli) or
  [LM Studio](https://lmstudio.ai) with a local model
- Optional for Garmin: Python 3.10+ (e.g. `brew install python`) and a Garmin
  Connect account
- Optional for Strava: Claude Code and access to
  [Strava's MCP server](https://mcp.strava.com/mcp)

## Build

```bash
git clone git@github.com:themb94/pace-lab.git
cd pace-lab
cp Config/Signing.local.example.xcconfig Config/Signing.local.xcconfig
```

Edit `Config/Signing.local.xcconfig` — your Team ID and a bundle ID of your
own (this file is ignored by git):

```
DEVELOPMENT_TEAM = ABCDE12345
PACELAB_BUNDLE_ID = com.yourname.pacelab
```

Open `PaceLab.xcodeproj`, select the **PaceLab** scheme and run. To install,
build the Release configuration and copy `Pace Lab.app` to `/Applications`.

## First launch

Pace Lab opens a setup window (also under *Pace Lab → Einrichtung …*):

1. **Training folder** — creates `~/Documents/Pace Lab` (or a folder you pick)
   with an example plan, empty run log, a coach README and a git repository.
2. **About you** — your name. Goals, max heart rate, training days or health
   notes go into the *Athletenprofil* section of the folder's `README.md` —
   or just tell the coach and it fills them in.
3. **Coach** — detects Claude Code, Codex and LM Studio and whether you are
   logged in (`claude auth login`, `codex login`).
4. **Garmin** (optional) — installs the bundled Garmin MCP server into its own
   Python environment and signs you in. Your password goes only to the local
   server process; only a token is stored (`~/.garminconnect`).
5. **Strava** (optional) — registers Strava's MCP server in Claude Code for
   your training folder and opens the browser sign-in.
6. **Start** — let the coach plan your first real block.

## How it works

```
Pace Lab.app ──reads/writes──▶ training folder (plan.json, analysis.json, completed.json, README.md, .git)
     │                                  ▲
     ├── Coach: runs `claude -p` / `codex exec` / `lms chat` in that folder
     ├── Garmin: talks MCP (stdio) to garmin-mcp/server.py (read-only unless you approve an upload)
     └── Strava: `claude -p` with only the two Strava read tools; the raw data is taken from the stream
```

- The coach follows the `README.md` in your training folder — that's where
  the rules, schemas and your athlete profile live. Adapt it to your liking.
- The Garmin server builds workouts straight from `plan.json`
  (`garmin-mcp/garmin_workouts.py`), so what you see is what lands on the watch.
- Available models (e.g. Opus, Sonnet, GPT versions) are read live from the
  installed CLIs — nothing is hard-coded.

## Project layout

```
PaceLab/          App (SwiftUI): Coach/, Planning/, Sync/, Project/ (git, JSON, MCP client), Setup/, Views/
PaceLabWidgets/   Widgets (WidgetKit)
Shared/           Models and calculations used by app and widgets
Template/         Contents of a new training folder (bundled into the app)
garmin-mcp/       Garmin MCP server (Python, bundled into the app)
Config/           Info.plists, entitlements, signing (Signing.xcconfig + your local override)
```

The Debug build can render screenshots of all views without clicking:
`"Pace Lab" -projectPath <copy-of-your-folder> -debugSnapshots <dir> -debugQuit YES`.

## Disclaimer

Pace Lab is a personal training tool, not medical advice — talk to a doctor
about health questions. The Garmin integration uses the unofficial
[`garminconnect`](https://github.com/cyberjunky/python-garminconnect) library
and may break when Garmin changes its login. Not affiliated with Garmin,
Strava, Anthropic or OpenAI.

## License

[MIT](LICENSE)
