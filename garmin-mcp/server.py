"""
Garmin workouts MCP server.

Creates structured running workouts from the plan (plan.json in the training folder, PACELAB_PLAN)
in Garmin Connect. Sign-in is token based (once via login.py, with MFA support); after that the
server needs no credentials.

Tools:
  garmin_status              – check the sign-in status
  garmin_login               – sign in (token or GARMIN_EMAIL/PASSWORD, MFA capable)
  garmin_submit_mfa          – submit the MFA code
  list_activities            – list recent Garmin activities (compact)
  get_activity_data          – fetch summary, splits and weather of an activity
  list_workouts              – list existing workouts in Garmin Connect
  preview_plan               – show planned workouts (no network)
  create_plan                – upload plan workouts to Garmin Connect (optionally replacing)
  delete_workout             – delete a workout
  schedule_workout           – put a workout on a date in the calendar

Messages meant for people are written in German when PACELAB_LANG=de (set by the Pace Lab app) and
in English otherwise.
"""
import json
import os

from mcp.server.fastmcp import FastMCP

from garmin_workouts import build_plan, make_payload, describe_steps

mcp = FastMCP("garmin-workouts")

# GARMIN_READONLY=1: tools that create/schedule/delete workouts are not offered at all.
# The Pace Lab Mac app uses this for coach engines without Garmin approval and for loading runs.
READONLY = os.environ.get("GARMIN_READONLY") == "1"
write_tool = (lambda f: f) if READONLY else mcp.tool()

TOKENSTORE = os.path.expanduser(os.environ.get("GARMIN_TOKENSTORE", "~/.garminconnect"))
LANG = os.environ.get("PACELAB_LANG") or ("de" if os.environ.get("LANG", "").startswith("de") else "en")


def _t(en, de):
    """Message for people: German if the app runs in German, English otherwise."""
    return de if LANG == "de" else en

_state = {"client": None, "mfa": None}


def _import_garmin():
    import garminconnect  # lazy import so the server starts without the library
    return garminconnect


def _client():
    """Returns a signed-in client or raises a descriptive exception."""
    if _state["client"] is not None:
        return _state["client"]
    garminconnect = _import_garmin()
    g = garminconnect.Garmin()
    g.login(TOKENSTORE)  # uses the stored tokens
    _state["client"] = g
    return g


@mcp.tool()
def garmin_status() -> str:
    """Checks whether a Garmin Connect sign-in exists (via stored tokens)."""
    try:
        g = _client()
        return _t(f"✅ Signed in as {g.get_full_name()}. Token store: {TOKENSTORE}",
                  f"✅ Angemeldet als {g.get_full_name()}. Tokenstore: {TOKENSTORE}")
    except Exception as e:
        return _t(f"❌ Not signed in ({type(e).__name__}: {e}).\nRun 'python login.py' once or use the garmin_login tool.",
                  f"❌ Nicht angemeldet ({type(e).__name__}: {e}).\nFühre einmalig 'python login.py' aus oder nutze das Tool garmin_login.")


@mcp.tool()
def garmin_login() -> str:
    """Signs in to Garmin Connect: first with a stored token, otherwise with
    GARMIN_EMAIL/GARMIN_PASSWORD (environment variables). If two-factor authentication
    is enabled, an MFA code is requested (then call garmin_submit_mfa)."""
    garminconnect = _import_garmin()
    # 1) try an existing token
    try:
        g = garminconnect.Garmin()
        g.login(TOKENSTORE)
        _state["client"] = g
        return _t(f"✅ Signed in via stored token as {g.get_full_name()}.",
                  f"✅ Über gespeichertes Token angemeldet als {g.get_full_name()}.")
    except Exception:
        pass
    # 2) fresh, with credentials
    email = os.environ.get("GARMIN_EMAIL")
    pw = os.environ.get("GARMIN_PASSWORD")
    if not email or not pw:
        return _t("❌ No valid token and no credentials set.\n"
                  "Recommended: run 'python login.py' once in Terminal (asks for email, "
                  "password and, if needed, an MFA code and stores the token).",
                  "❌ Kein gültiges Token und keine Zugangsdaten gesetzt.\n"
                  "Empfohlen: einmalig 'python login.py' im Terminal ausführen (fragt nach "
                  "E-Mail, Passwort und ggf. MFA-Code und speichert das Token).")
    try:
        g = garminconnect.Garmin(email=email, password=pw, is_cn=False, return_on_mfa=True)
        res1, res2 = g.login()
        if res1 == "needs_mfa":
            _state["mfa"] = (g, res2)
            return _t("🔐 MFA required. Please send the 6-digit code with the garmin_submit_mfa tool.",
                      "🔐 MFA nötig. Bitte den 6-stelligen Code per Tool garmin_submit_mfa senden.")
        _state["client"] = g
        g.client.dump(TOKENSTORE)
        return _t(f"✅ Signed in as {g.get_full_name()}. Token saved in {TOKENSTORE}.",
                  f"✅ Angemeldet als {g.get_full_name()}. Token gespeichert in {TOKENSTORE}.")
    except Exception as e:
        return _t(f"❌ Login failed: {type(e).__name__}: {e}", f"❌ Login fehlgeschlagen: {type(e).__name__}: {e}")


@mcp.tool()
def garmin_submit_mfa(code: str) -> str:
    """Submits the one-time MFA code after garmin_login reported that MFA is required."""
    if not _state.get("mfa"):
        return _t("No MFA process open. Call garmin_login first.", "Kein MFA-Vorgang offen. Zuerst garmin_login aufrufen.")
    g, res2 = _state["mfa"]
    try:
        g.resume_login(res2, code.strip())
        _state["client"] = g
        _state["mfa"] = None
        g.client.dump(TOKENSTORE)
        return _t(f"✅ Signed in as {g.get_full_name()}. Token saved in {TOKENSTORE}.",
                  f"✅ Angemeldet als {g.get_full_name()}. Token gespeichert in {TOKENSTORE}.")
    except Exception as e:
        return _t(f"❌ MFA failed: {type(e).__name__}: {e}", f"❌ MFA fehlgeschlagen: {type(e).__name__}: {e}")


@mcp.tool()
def list_activities(limit: int = 5, activity_type: str = "running") -> str:
    """Lists the latest Garmin activities compactly. By default the last five running
    activities are returned. activity_type="" disables the sport filter."""
    try:
        g = _client()
        data = g.get_activities(0, max(1, min(limit, 50)), activity_type or None)
        compact = []
        for a in data or []:
            compact.append({
                "activityId": a.get("activityId"),
                "activityName": a.get("activityName"),
                "startTimeLocal": a.get("startTimeLocal"),
                "activityType": (a.get("activityType") or {}).get("typeKey"),
                "distance_m": a.get("distance"),
                "duration_s": a.get("duration"),
                "movingDuration_s": a.get("movingDuration"),
                "elevationGain_m": a.get("elevationGain"),
                "averageHR": a.get("averageHR"),
                "maxHR": a.get("maxHR"),
                "averageCadence_spm": a.get("averageRunningCadenceInStepsPerMinute"),
                "trainingEffect": a.get("aerobicTrainingEffect"),
                "trainingLoad": a.get("activityTrainingLoad"),
            })
        return json.dumps(compact, ensure_ascii=False, indent=2)
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"


@mcp.tool()
def get_activity_data(activity_id: str) -> str:
    """Returns the Garmin data relevant for a run analysis: summary, kilometer/workout
    laps and Garmin weather. Deliberately without GPS track and without per-second
    series so that the MCP response stays compact."""
    try:
        g = _client()
        activity = g.get_activity(activity_id)
        split_data = g.get_activity_splits(activity_id)
        try:
            weather = g.get_activity_weather(activity_id)
        except Exception as e:
            weather = {"error": f"{type(e).__name__}: {e}"}

        summary = activity.get("summaryDTO") or {}
        summary_keys = [
            "startTimeLocal", "distance", "duration", "movingDuration",
            "elapsedDuration", "elevationGain", "elevationLoss", "averageSpeed",
            "maxSpeed", "averageHR", "maxHR", "averageRunCadence",
            "maxRunCadence", "averageTemperature", "minTemperature",
            "maxTemperature", "averagePower", "maxPower", "trainingEffect",
            "anaerobicTrainingEffect", "trainingEffectLabel", "activityTrainingLoad",
            "directWorkoutFeel", "directWorkoutRpe", "differenceBodyBattery",
        ]
        lap_keys = [
            "lapIndex", "distance", "duration", "movingDuration", "elapsedDuration",
            "elevationGain", "elevationLoss", "averageSpeed", "maxSpeed",
            "averageHR", "maxHR", "averageRunCadence", "maxRunCadence",
            "averagePower", "maxPower", "averageTemperature", "intensityType",
        ]
        laps = [
            {k: lap.get(k) for k in lap_keys}
            for lap in (split_data.get("lapDTOs") or [])
            if (lap.get("distance") or 0) >= 100
        ]
        result = {
            "source": "garmin",
            "activityId": activity.get("activityId"),
            "activityName": activity.get("activityName"),
            "activityType": (activity.get("activityTypeDTO") or {}).get("typeKey"),
            "summary": {k: summary.get(k) for k in summary_keys},
            "laps": laps,
            "weather": weather,
        }
        return json.dumps(result, ensure_ascii=False, indent=2)
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"


@mcp.tool()
def list_workouts() -> str:
    """Lists your own workouts in the Garmin Connect account (name + ID)."""
    try:
        g = _client()
        data = g.connectapi("/workout-service/workouts?start=0&limit=100&myWorkoutsOnly=true")
        if not data:
            return _t("No workouts found.", "Keine Workouts vorhanden.")
        lines = [f"{w.get('workoutId')}  {w.get('workoutName')}" for w in data]
        return f"{len(lines)} workouts:\n" + "\n".join(lines)
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"


@mcp.tool()
def preview_plan(week: int = 0) -> str:
    """Shows the planned workouts from plan.json as a structure WITHOUT uploading anything.
    week=0 for all weeks, otherwise the block week (1 to number of weeks)."""
    plan = build_plan()
    sel = [w for w in plan if week == 0 or w["week"] == week]
    if not sel:
        return _t(f"No workouts for week {week}.", f"Keine Workouts für Woche {week}.")
    out = [f"{len(sel)} workouts:" + ("" if week else " (all weeks)")]
    for w in sel:
        out.append(f"\n### {w['name']}")
        out.extend(describe_steps(w["steps"]))
    return "\n".join(out)


@write_tool
def create_plan(week: int = 0, dry_run: bool = False, replace_existing: bool = False) -> str:
    """Creates the plan workouts from plan.json in Garmin Connect (they then appear on the
    watch under Training › Workouts). week=0 = all weeks, otherwise the block week.
    dry_run=True only shows what would be created. replace_existing=True first deletes
    workouts with the same name (e.g. after a plan change) instead of creating duplicates."""
    plan = build_plan()
    # Easy runs are only created if the plan sets "uploadEasyRuns": true.
    sel = [w for w in plan if (week == 0 or w["week"] == week) and w["upload"]]
    if not sel:
        return _t(f"No (non-easy) workouts for week {week}.", f"Keine (nicht-lockeren) Workouts für Woche {week}.")
    if dry_run:
        return _t("Dry run — would be created:\n", "Dry-Run — es würde angelegt:\n") + "\n".join(w["name"] for w in sel)
    try:
        g = _client()
    except Exception as e:
        return _t(f"❌ Not signed in: {type(e).__name__}: {e}", f"❌ Nicht angemeldet: {type(e).__name__}: {e}")
    existing = {}
    if replace_existing:
        try:
            for item in g.connectapi("/workout-service/workouts?start=0&limit=200&myWorkoutsOnly=true") or []:
                existing.setdefault(item.get("workoutName"), []).append(item.get("workoutId"))
        except Exception as e:
            return _t(f"❌ Existing workouts could not be fetched: {type(e).__name__}: {e}", f"❌ Vorhandene Workouts nicht abrufbar: {type(e).__name__}: {e}")
    results = []
    for w in sel:
        for old_id in existing.get(w["name"], []):
            try:
                g.client.delete("connectapi", f"/workout-service/workout/{old_id}", api=True)
                results.append(_t(f"♻️ {w['name']}: old workout {old_id} deleted", f"♻️ {w['name']}: altes Workout {old_id} gelöscht"))
            except Exception as e:
                results.append(_t(f"❌ {w['name']}: old workout {old_id} not deleted ({type(e).__name__}: {e})",
                                  f"❌ {w['name']}: altes Workout {old_id} nicht gelöscht ({type(e).__name__}: {e})"))
        payload = make_payload(w["name"], w["steps"])
        try:
            resp = g.client.post("connectapi", "/workout-service/workout", api=True, json=payload)
            wid = resp.get("workoutId") if isinstance(resp, dict) else None
            results.append(f"✅ {w['name']} → ID {wid}")
        except Exception as e:
            results.append(f"❌ {w['name']}: {type(e).__name__}: {e}")
    ok = sum(1 for r in results if r.startswith("✅"))
    return _t(f"{ok}/{len(sel)} workouts created:\n", f"{ok}/{len(sel)} Workouts angelegt:\n") + "\n".join(results)


@write_tool
def delete_workout(workout_id: str) -> str:
    """Deletes a workout by its ID from Garmin Connect."""
    try:
        g = _client()
        g.client.delete("connectapi", f"/workout-service/workout/{workout_id}", api=True)
        return _t(f"✅ Workout {workout_id} deleted.", f"✅ Workout {workout_id} gelöscht.")
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"


@write_tool
def schedule_workout(workout_id: str, date: str) -> str:
    """Puts a workout on a date (YYYY-MM-DD) in the Garmin calendar."""
    try:
        g = _client()
        g.client.post("connectapi", f"/workout-service/schedule/{workout_id}",
                      api=True, json={"date": date})
        return _t(f"✅ Workout {workout_id} scheduled for {date}.", f"✅ Workout {workout_id} für {date} eingeplant.")
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"


if __name__ == "__main__":
    mcp.run()
