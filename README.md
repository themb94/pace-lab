# Pace Lab

A macOS app for planning and analysing your running training — with desktop
widgets, Garmin/Polar/Strava sync and an AI coach that runs on your own machine
through **Claude Code**, **Codex** or a **local model** (LM Studio).

> The app speaks **English** and **German**. It follows your system language:
> German systems get German, every other language gets English. The coach answers
> in the same language.

- **Plan** — training blocks in a simple JSON file, every session with its
  structured workout (warm-up, intervals, pace targets). Tick sessions off,
  see planned vs. run kilometres per week. Every session is a bar — length =
  distance, color = intensity (its heart-rate zone), filled once run — so the
  whole block fits on one screen, one row per week.
- **Runs** — load new runs from **Garmin Connect** or **Polar Flow** (directly,
  no AI involved) or **Strava** (through Claude Code). Splits, heart-rate zones, analysis.
  With Garmin also the **running dynamics** (cadence, stride length, ground contact
  time and balance, vertical oscillation and ratio) on Garmin's color scale, how they
  change during the run, and the coach's recommendations for a better running form.
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

- A Mac with macOS 26 or newer
- At least one coach:
  [Claude Code](https://docs.claude.com/en/docs/claude-code/setup),
  [Codex](https://developers.openai.com/codex/cli) or
  [LM Studio](https://lmstudio.ai) with a local model
- Optional for Garmin or Polar: Python 3.10+ (e.g. `brew install python`) and a
  Garmin Connect or Polar Flow account
- Optional for Strava: Claude Code and a Strava subscription (Strava offers its
  connection for AI tools to subscribers only)

## Build

There is no ready-made download yet — you build Pace Lab once yourself with
Xcode 26. A free Apple account is enough: the app has to be signed with your own
team, which Xcode does for you.

```bash
git clone git@github.com:themb94/pace-lab.git
cd pace-lab
cp Config/Signing.local.example.xcconfig Config/Signing.local.xcconfig
```

Edit `Config/Signing.local.xcconfig` — your Team ID (Xcode → Settings → Accounts)
and a bundle ID of your own:

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
   later in *Settings → Runs*). The app sets up the connection and signs you in:
   - *Garmin:* your password is only used to sign in; afterwards only a token is
     kept on your Mac.
   - *Polar:* uses Polar's official interface. Create a free client at
     [admin.polaraccesslink.com](https://admin.polaraccesslink.com) with the
     redirect URL `http://localhost:8721/pacelab/callback`, enter its ID and secret,
     then approve access in the browser.
5. **Strava** (optional) — connects Strava to Claude Code for your training
   folder and opens the browser sign-in.
6. **Start** — let the coach plan your first real block.

## Profiles

Several people can train with Pace Lab on the same Mac. Every profile is
completely separate: its own training folder, settings, coach conversations,
sign-ins (Claude Code, Codex, Garmin or Polar) and watch. Your first profile
keeps the sign-ins you already have on this Mac.

Switch profiles in the sidebar (bottom left), in the menu bar or under
*Pace Lab → Profile*. *New profile …* asks for a name and opens the setup.
Deleting a profile in *Settings → Profiles* removes its settings, conversations
and sign-ins — the training folder stays. Widgets show the active profile; in
*Edit widget* you can pin one to a profile.

## Good to know

- The coach follows the `README.md` in your training folder — that's where
  the rules and your athlete profile live. Adapt it to your liking.
- Every change to your plan — by the coach, a tick or a loaded run — can be
  undone under *History*.
- Workouts on a Garmin watch are built straight from your plan, so what you see
  is what lands on the watch.
- Polar lets no other app put training targets on the watch. Pace Lab shows a
  week as phases (name, length, heart-rate or pace range) to enter in Polar Flow
  under *Training target → Phased*. Polar only passes on sessions from the last
  30 days, without laps — Pace Lab computes the kilometer splits itself.
- A session that is dropped from the plan shows as struck through as soon as its
  description starts with "skipped" (German: "entfällt") — the coach does that
  for you.

## Disclaimer

Pace Lab is a personal training tool, not medical advice — talk to a doctor
about health questions. The Garmin integration uses the unofficial
[`garminconnect`](https://github.com/cyberjunky/python-garminconnect) library
and may break when Garmin changes its login. Not affiliated with Garmin, Polar,
Strava, Anthropic or OpenAI.

## License

[MIT](LICENSE)
