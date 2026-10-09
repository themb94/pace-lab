# Pace Lab

A macOS app for planning and analysing your running training — with desktop
widgets, Garmin/Polar/Strava sync and an AI coach that runs on your own machine
through **Claude Code**, **Codex** or a **local model** (LM Studio).

> The app speaks **English** and **German**. It follows your system language:
> German systems get German, every other language gets English. The coach answers
> in the same language.

- **Plan** — training blocks in a simple JSON file, every session with its
  structured workout (warm-up, intervals, pace targets). Tick sessions off,
  see planned vs. run kilometres per week.
- **Runs** — load new runs from **Garmin Connect** or **Polar Flow** (directly,
  no AI involved) or **Strava** (through Claude Code). Splits, heart-rate zones, analysis.
- **Coach** — weekly review, adjusting a week, planning a whole new block. The
  coach edits your plan files; every change is versioned with git and can be
  undone. Garmin workouts are only created after your explicit approval.
- **Watch** — Garmin: send a week's workouts to your watch. Polar: the week as
  phased training targets, ready to enter in Polar Flow (Polar allows no upload).
- **Widgets** — next session, week progress, last run.
- **Profiles** — several people on one Mac, each with a completely separate
  Pace Lab: own training folder, coach, settings and sign-ins.

Everything stays on your Mac: your training data lives in a folder you choose,
logins stay with Garmin, Polar, Strava and the CLIs you already use. Pace Lab has no
server, no account and no telemetry.

## Requirements

- macOS 26 or newer, Xcode 26 or newer
- An Apple developer team to sign the app (a free Personal Team from
  Xcode → Settings → Accounts should do)
- At least one coach:
  [Claude Code](https://docs.claude.com/en/docs/claude-code/setup),
  [Codex](https://developers.openai.com/codex/cli) or
  [LM Studio](https://lmstudio.ai) with a local model
- Optional for Garmin or Polar: Python 3.10+ (e.g. `brew install python`) and a
  Garmin Connect or Polar Flow account
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

Pace Lab opens a setup window (also under *Pace Lab → Setup …*):

1. **Training folder** — creates `~/Documents/Pace Lab` (or a folder you pick)
   with an example plan, empty run log, a coach README and a git repository.
2. **About you** — your name. Goals, max heart rate, training days or health
   notes go into the *Athlete profile* section of the folder's `README.md` —
   or just tell the coach and it fills them in.
3. **Coach** — detects Claude Code, Codex and LM Studio and whether you are
   logged in (`claude auth login`, `codex login`).
4. **Watch** (optional) — choose **Garmin**, **Polar** or none (you can switch
   later in *Settings → Runs*). The app installs the bundled MCP server for it into
   its own Python environment and signs you in:
   - *Garmin:* your password goes only to the local server process; only a token
     is stored (`~/.garminconnect`).
   - *Polar:* uses Polar's official AccessLink API. Create a free client at
     [admin.polaraccesslink.com](https://admin.polaraccesslink.com) with the
     redirect URL `http://localhost:8721/pacelab/callback`, enter its ID and secret,
     then approve access in the browser. Only the token and the client are stored.
5. **Strava** (optional) — registers Strava's MCP server in Claude Code for
   your training folder and opens the browser sign-in.
6. **Start** — let the coach plan your first real block.

## Profiles

Several people can train with Pace Lab on the same Mac. Every profile is
completely separate and is set up on its own:

- its own **training folder** (plan, runs, history) — a folder belongs to one profile only,
- its own **settings** (coach CLIs and models, source for “Load runs”) and **coach conversations**,
- its own **sign-ins**: Claude Code (`CLAUDE_CONFIG_DIR`) and Codex (`CODEX_HOME`)
  get a configuration folder per profile — with its own login, Strava connection,
  memory and sessions —, and the Garmin or Polar token lives per profile as well,
- its own **watch**: Garmin, Polar or none.

The first profile (*main profile*) keeps the app's original locations and the
sign-ins of the Mac (`~/.claude`, `~/.codex`, `~/.garminconnect`), so an
existing setup keeps working unchanged. Further profiles keep everything in
`~/Library/Application Support/Pace Lab/Profiles/<id>`; their settings are in
their own UserDefaults domain.

Switch profiles in the sidebar (bottom left), in the menu bar or under
*Pace Lab → Profile*. *New profile …* asks for a name and opens the setup.
*Settings → Profiles* lists all profiles; deleting one signs its CLIs out and
removes its settings, conversations and sign-ins — the training folder stays.
Widgets show the active profile; in *Edit widget* you can pin one to a profile.

## How it works

```
Pace Lab.app ──reads/writes──▶ training folder (plan.json, analysis.json, completed.json, README.md, .git)
     │                                  ▲
     ├── Coach: runs `claude -p` / `codex exec` / `lms chat` in that folder
     ├── Garmin: talks MCP (stdio) to garmin-mcp/server.py (read-only unless you approve an upload)
     ├── Polar: talks MCP (stdio) to polar-mcp/server.py (Polar AccessLink, read-only)
     └── Strava: `claude -p` with only the two Strava read tools; the raw data is taken from the stream
```

- The coach follows the `README.md` in your training folder — that's where
  the rules, schemas and your athlete profile live. Adapt it to your liking.
- The Garmin server builds workouts straight from `plan.json`
  (`garmin-mcp/garmin_workouts.py`), so what you see is what lands on the watch.
- Polar lets no other app put training targets on the watch. Pace Lab shows a
  week as phases (name, length, heart-rate or pace range) to enter in Polar Flow
  under *Training target → Phased*. Polar only passes on sessions from the last
  30 days that were synced after you linked the client, and no lap data — the
  Polar server computes kilometer splits from the watch's samples.
- Available models (e.g. Opus, Sonnet, GPT versions) are read live from the
  installed CLIs — nothing is hard-coded.

## Project layout

```
PaceLab/          App (SwiftUI): Coach/, Planning/, Sync/, Project/ (git, JSON, MCP client), Setup/, Views/
PaceLabWidgets/   Widgets (WidgetKit)
Shared/           Models and calculations used by app and widgets, and the translations (Localizable.xcstrings)
Template/         Contents of a new training folder, per language: Template/en, Template/de (bundled into the app)
garmin-mcp/       Garmin MCP server (Python, bundled into the app)
polar-mcp/        Polar MCP server (Python, Polar AccessLink; tests: python3 -m unittest test_polar)
Config/           Info.plists, entitlements, signing (Signing.xcconfig + your local override)
scripts/          Release build: signed, notarized DMG (release.sh)
```

The Debug build can render screenshots of all views without clicking:
`"Pace Lab" -projectPath <copy-of-your-folder> -debugSnapshots <dir> -debugQuit YES`.
Add `-debugSupportDirectory <dir>` to keep profiles, conversations and settings
apart from your real ones; `-debugProfile <name> -debugProfileFolder <dir>`
then tries out a separate profile (see `PaceLab/DebugSnapshots.swift`).

## Languages

Texts are written in English in the source and translated through a
[String Catalog](Shared/Localizable.xcstrings) (`Shared/Localizable.xcstrings`,
shared by the app and the widgets). German is included. To add a language, add
its translations to the catalog in Xcode and create a matching folder
`Template/<language>` (coach README and example plan; the app falls back to
`Template/en`). The language the coach replies in follows the app language.

Your own data stays as you wrote it: plan texts, run analyses and the coach's
notes in your training folder are not translated.

## Release build (maintainers)

`scripts/release.sh` builds a DMG for distribution: signed with a *Developer ID
Application* certificate, notarized by Apple and stapled, so Gatekeeper opens it
without warnings on other Macs. It needs a paid Apple Developer Program
membership. Team and bundle ID come from `Config/Signing.local.xcconfig`, the
Apple credentials from your keychain — nothing personal lives in the repository.

1. Create a *Developer ID Application* certificate (Xcode → Settings → Accounts →
   Manage Certificates, or developer.apple.com — pick the **G2** authority when
   asked). Certificates from the older authority expire on 2027-02-01; the script
   shows your certificate's expiry and warns if it comes from the old chain.
2. Store notary credentials once (asks for an app-specific password from
   account.apple.com):
   `xcrun notarytool store-credentials pacelab-notary --apple-id <you@example.com> --team-id <TEAMID>`
3. Run `scripts/release.sh`. The DMG lands in `build/release/`.
   `--no-notarize` is a dry run, `--upload` attaches the DMG to the GitHub
   release `v<version>`.

Apps that were signed and notarized stay valid after the certificate expires.
Only new releases need a renewed certificate.

## Disclaimer

Pace Lab is a personal training tool, not medical advice — talk to a doctor
about health questions. The Garmin integration uses the unofficial
[`garminconnect`](https://github.com/cyberjunky/python-garminconnect) library
and may break when Garmin changes its login. Not affiliated with Garmin, Polar,
Strava, Anthropic or OpenAI.

## License

[MIT](LICENSE)
