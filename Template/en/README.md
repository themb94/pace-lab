# Training folder (Pace Lab)

This folder contains your training plan and your run reviews. The app **Pace Lab**
shows and edits the files, the **coach** (Claude Code, Codex or a local model)
reads this README before every conversation. Everything written here counts as an
instruction for the coach — adapt it to yourself.

## Athlete profile

> Fill it in or tell the coach in the chat (“Add to my athlete profile …”).
> Engines without file access (local models) get this section sent along.

- **Name:**
- **Goal:** (e.g. “10 km under 55 minutes”, “half marathon in spring”, “get fitter”)
- **Current volume:** (runs per week, km per week, longest recent run)
- **Current form / personal bests:**
- **Max heart rate:** (measured or estimated — also in `plan.json` → `athlete`)
- **Training days / time windows:**
- **Health / special considerations:** (optional — only to interpret the data, the
  coach gives no medical advice)
- **Preferences:** (e.g. “easy runs without heart-rate alerts”, “intervals preferably on the track”)

## Training principles

Default rules — change them if you want it differently:

1. **Easy runs by feel**, without a pace or heart-rate target on the watch. By
   default they are not created as a Garmin workout (`"uploadEasyRuns": true` in
   `plan.json` changes that).
2. **Long runs** have a distance only, no pace target.
3. **Pace targets** only for the hard segments of a quality session; warm-up,
   cool-down and jog recoveries are free. Prefer wide bands (20–40 s) over narrow
   ones so the watch doesn't alert all the time.
4. **At most two demanding sessions per week**, a recovery week every 3–4 weeks.
5. **Week by week:** first review the week that just ended, then prepare the next
   one — don't load anything onto the watch in advance.
6. **A high heart rate** is explained first with heat, hills, form of the day
   (sleep, stress) or health factors, before fitness is questioned.
7. **No medical advice** (medication, dosages) — that is for a doctor.

## Files

```
plan.json            Active plan: weeks, sessions, workout steps, pace bands, HR zones
plan-entwurf.json    (temporary) draft for the next block ("entwurf" = draft) — applied in the app
plans/               Earlier blocks (stored when a draft is applied)
analysis.json        All runs with measurements and review
completed.json       Which sessions are done
.mcp.json            Connection of the Garmin server (created by the app)
.git/                History — every change is a version and can be undone
```

## Plan schema (`plan.json`)

```jsonc
{
  "title": "Base block", "goal": "…", "subtitle": "…", "previous": "…",
  "startMonday": "2026-01-05",       // Monday of the first block week
  "idPrefix": "b1",                  // session IDs: b1w1-tempo-0 … (new for each block!)
  "workoutPrefix": "PL",             // Garmin names: "PL W01 · 6x800m" (new for each block)
  "uploadEasyRuns": false,           // also send easy runs to the watch?
  "athlete": { "maxHr": 190, "zoneFloors": [114, 133, 152, 171] },   // lower limits of Z2–Z5
  "paceBands": [{ "name": "Tempo", "range": "5:45–6:15", "note": "…" }],
  "weeks": [{
    "phase": "Build", "note": "",
    "sessions": [{
      "type": "tempo",               // tempo | easy | long | race (order = index in the ID)
      "dist": "~8 km", "desc": "6×800 m brisk · 90 s jog recovery",
      "workout": {
        "name": "6x800m",
        "steps": [
          { "type": "warmup", "time": 600, "note": "Easy warm-up" },
          { "repeat": 6, "steps": [
            { "type": "interval", "distance": 800, "pace": "Intervals", "note": "800 m brisk" },
            { "type": "recovery", "time": 90, "note": "90 s easy jog" } ] },
          { "type": "cooldown", "time": 600, "note": "Easy cool-down" } ] } }] }]
}
```

- **Steps:** `type` = `warmup` | `cooldown` | `interval` | `recovery` | `run`;
  end by `distance` (meters) **or** `time` (seconds); `repeat` + `steps` for
  repetitions.
- **Targets:** `"pace"` = name of a `paceBands` entry (preferred) or
  `"m:ss-m:ss"`; `"hr": "lo-hi"` (+ optional `"zone"`). Without a target = by feel.
- **Session IDs** (`{idPrefix}w{week}-{type}-{index}`) depend on type and position:
  for sessions that are already ticked off, don't change type or order.
- **Format:** 2 spaces indentation, short objects on one line (up to ~120 characters).
- **New block:** as `plan-entwurf.json` with a **new** `idPrefix` and
  `workoutPrefix`; `plan.json` stays until the draft is applied in the app.

## Runs (`analysis.json`)

Newest first. Schema per run:

```jsonc
{
  "source": "garmin",            // "garmin" | "strava" — set when the app loaded the run
  "garminId": "…",               // or "stravaId"
  "sessionId": "b1w1-tempo-0",   // or null for unplanned runs
  "tag": "…",                    // only if sessionId is null, e.g. "recovery"
  "name": "…", "date": "2026-01-06",
  "distance_km": 7.4, "moving_time_s": 2710, "avg_pace_s": 366,
  "avg_hr": 151, "max_hr": 178, "elevation_gain": 40, "cadence": 84,
  "weather": "…",                // optional
  "flags": ["…"],                // short notes
  "splits": [ { "km": 1, "pace_s": 381, "hr": 138 }, { "label": "Interval 1", "pace_s": 330, "hr": 165 } ],
  "verdict": "good",             // "good" | "ok" | "warning"
  "analysis": "…",               // review as running text
  "adjustments": "…"             // consequence for next week, or null
}
```

Week summaries go into `weekSummaries: [{ "week": 1, "analysis": "…", "nextWeekChanges": "…" }]`.

**Runs loaded by the app** (with `source` and `verdict: null`) are **completed
instead of created anew** during the review: keep IDs and measurements, make
split labels more precise for intervals, set `sessionId`, `flags`, `verdict`,
`analysis`, `adjustments`.

## Completed sessions (`completed.json`)

`{ "b1w1-tempo-0": "06.01.2026", … }` — the key is the session ID, the value the
date (`DD.MM.YYYY`). Keep the order of existing entries.

## Weekly review

1. **Fetch runs** — Strava through the Strava MCP (`list_activities`,
   `get_activity_performance`) if set up, otherwise Garmin
   (`list_activities`, `get_activity_data`). The app has often loaded them already.
2. **Reconstruct the structure:** for interval workouts, consecutive laps add up
   to the planned segments.
3. Update `completed.json` and `analysis.json`, write the week summary into `weekSummaries`.
4. Short summary: runs, rating, recommendation for next week.
5. Only then prepare the next week (`plan.json`). Create Garmin workouts only with
   explicit approval.

## Garmin

The Garmin server (MCP) is set up by Pace Lab and registered in `.mcp.json`. Tools:
`garmin_status`, `list_activities`, `get_activity_data`, `list_workouts`,
`preview_plan(week)`, `create_plan(week, dry_run, replace_existing)`,
`delete_workout(id)`, `schedule_workout(id, date)`. The workouts are built from
`plan.json`; `replace_existing=true` replaces workouts with the same name instead
of duplicating them. Create, schedule and delete only with approval.

## Version control

The folder is a git repository. Pace Lab records every change as a version (coach
runs, ticks, loaded runs) and can undo it. **As the coach, don't run any git
commands** — reading (`git log`, `git diff`) is fine.
