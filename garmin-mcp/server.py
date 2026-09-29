"""
Garmin-Workouts MCP-Server.

Legt strukturierte Laufworkouts aus dem Plan (plan.json im Trainingsordner, PACELAB_PLAN)
in Garmin Connect an. Die Anmeldung läuft token-basiert (einmalig via login.py, mit
MFA-Unterstützung); der Server selbst braucht dann keine Zugangsdaten mehr.

Tools:
  garmin_status              – Anmeldestatus prüfen
  garmin_login               – anmelden (Token oder GARMIN_EMAIL/PASSWORD, MFA-fähig)
  garmin_submit_mfa          – MFA-Code nachreichen
  list_activities            – letzte Garmin-Aktivitäten kompakt auflisten
  get_activity_data          – Zusammenfassung, Splits und Wetter einer Aktivität abrufen
  list_workouts              – vorhandene Workouts in Garmin Connect auflisten
  preview_plan               – geplante Workouts anzeigen (kein Netzwerk)
  create_plan                – Plan-Workouts nach Garmin Connect hochladen (optional ersetzen)
  delete_workout             – Workout löschen
  schedule_workout           – Workout auf ein Datum im Kalender legen
"""
import json
import os

from mcp.server.fastmcp import FastMCP

from garmin_workouts import build_plan, make_payload, describe_steps

mcp = FastMCP("garmin-workouts")

# GARMIN_READONLY=1: Werkzeuge, die Workouts anlegen/einplanen/löschen, werden gar nicht angeboten.
# Nutzt die Mac-App Pace Lab für Coach-Engines ohne Garmin-Freigabe und zum Laden von Läufen.
READONLY = os.environ.get("GARMIN_READONLY") == "1"
write_tool = (lambda f: f) if READONLY else mcp.tool()

TOKENSTORE = os.path.expanduser(os.environ.get("GARMIN_TOKENSTORE", "~/.garminconnect"))

_state = {"client": None, "mfa": None}


def _import_garmin():
    import garminconnect  # verzögerter Import, damit der Server ohne Lib startet
    return garminconnect


def _client():
    """Liefert einen angemeldeten Client oder wirft eine sprechende Exception."""
    if _state["client"] is not None:
        return _state["client"]
    garminconnect = _import_garmin()
    g = garminconnect.Garmin()
    g.login(TOKENSTORE)  # nutzt gespeicherte Tokens
    _state["client"] = g
    return g


@mcp.tool()
def garmin_status() -> str:
    """Prüft, ob eine Anmeldung bei Garmin Connect besteht (über gespeicherte Tokens)."""
    try:
        g = _client()
        return f"✅ Angemeldet als {g.get_full_name()}. Tokenstore: {TOKENSTORE}"
    except Exception as e:
        return (f"❌ Nicht angemeldet ({type(e).__name__}: {e}).\n"
                f"Führe einmalig 'python login.py' aus oder nutze das Tool garmin_login.")


@mcp.tool()
def garmin_login() -> str:
    """Meldet sich bei Garmin Connect an: zuerst per gespeichertem Token,
    sonst per GARMIN_EMAIL/GARMIN_PASSWORD (Umgebungsvariablen). Bei aktivierter
    2-Faktor-Authentifizierung wird ein MFA-Code angefordert (dann garmin_submit_mfa)."""
    garminconnect = _import_garmin()
    # 1) Vorhandenes Token versuchen
    try:
        g = garminconnect.Garmin()
        g.login(TOKENSTORE)
        _state["client"] = g
        return f"✅ Über gespeichertes Token angemeldet als {g.get_full_name()}."
    except Exception:
        pass
    # 2) Frisch mit Zugangsdaten
    email = os.environ.get("GARMIN_EMAIL")
    pw = os.environ.get("GARMIN_PASSWORD")
    if not email or not pw:
        return ("❌ Kein gültiges Token und keine Zugangsdaten gesetzt.\n"
                "Empfohlen: einmalig 'python login.py' im Terminal ausführen (fragt nach "
                "E-Mail, Passwort und ggf. MFA-Code und speichert das Token).")
    try:
        g = garminconnect.Garmin(email=email, password=pw, is_cn=False, return_on_mfa=True)
        res1, res2 = g.login()
        if res1 == "needs_mfa":
            _state["mfa"] = (g, res2)
            return "🔐 MFA nötig. Bitte den 6-stelligen Code per Tool garmin_submit_mfa senden."
        _state["client"] = g
        g.client.dump(TOKENSTORE)
        return f"✅ Angemeldet als {g.get_full_name()}. Token gespeichert in {TOKENSTORE}."
    except Exception as e:
        return f"❌ Login fehlgeschlagen: {type(e).__name__}: {e}"


@mcp.tool()
def garmin_submit_mfa(code: str) -> str:
    """Reicht den MFA-Einmalcode nach, nachdem garmin_login 'MFA nötig' gemeldet hat."""
    if not _state.get("mfa"):
        return "Kein MFA-Vorgang offen. Zuerst garmin_login aufrufen."
    g, res2 = _state["mfa"]
    try:
        g.resume_login(res2, code.strip())
        _state["client"] = g
        _state["mfa"] = None
        g.client.dump(TOKENSTORE)
        return f"✅ Angemeldet als {g.get_full_name()}. Token gespeichert in {TOKENSTORE}."
    except Exception as e:
        return f"❌ MFA fehlgeschlagen: {type(e).__name__}: {e}"


@mcp.tool()
def list_activities(limit: int = 5, activity_type: str = "running") -> str:
    """Listet die neuesten Garmin-Aktivitäten kompakt auf. Standardmäßig werden
    die letzten fünf Laufaktivitäten geliefert. activity_type="" deaktiviert
    den Sportartfilter."""
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
    """Liefert die für eine Laufanalyse relevanten Garmin-Daten: Zusammenfassung,
    Kilometer-/Workout-Laps und Garmin-Wetter. Bewusst ohne GPS-Track und ohne
    sekündliche Messreihen, damit die MCP-Antwort kompakt bleibt."""
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
    """Listet die eigenen Workouts im Garmin-Connect-Konto (Name + ID)."""
    try:
        g = _client()
        data = g.connectapi("/workout-service/workouts?start=0&limit=100&myWorkoutsOnly=true")
        if not data:
            return "Keine Workouts vorhanden."
        lines = [f"{w.get('workoutId')}  {w.get('workoutName')}" for w in data]
        return f"{len(lines)} Workouts:\n" + "\n".join(lines)
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"


@mcp.tool()
def preview_plan(week: int = 0) -> str:
    """Zeigt die geplanten Workouts aus plan.json als Struktur an, OHNE etwas hochzuladen.
    week=0 für alle Wochen, sonst die Blockwoche (1 bis Anzahl Wochen)."""
    plan = build_plan()
    sel = [w for w in plan if week == 0 or w["week"] == week]
    if not sel:
        return f"Keine Workouts für Woche {week}."
    out = [f"{len(sel)} Workouts:" + ("" if week else " (alle Wochen)")]
    for w in sel:
        out.append(f"\n### {w['name']}")
        out.extend(describe_steps(w["steps"]))
    return "\n".join(out)


@write_tool
def create_plan(week: int = 0, dry_run: bool = False, replace_existing: bool = False) -> str:
    """Legt die Plan-Workouts aus plan.json in Garmin Connect an (erscheinen danach auf
    der Uhr unter Training › Workouts). week=0 = alle Wochen, sonst die Blockwoche.
    dry_run=True zeigt nur, was angelegt würde. replace_existing=True löscht vorher
    Workouts mit gleichem Namen (z. B. nach einer Planänderung), statt Duplikate anzulegen."""
    plan = build_plan()
    # Lockere Läufe werden nur angelegt, wenn der Plan "uploadEasyRuns": true setzt.
    sel = [w for w in plan if (week == 0 or w["week"] == week) and w["upload"]]
    if not sel:
        return f"Keine (nicht-lockeren) Workouts für Woche {week}."
    if dry_run:
        return "Dry-Run — es würde angelegt:\n" + "\n".join(w["name"] for w in sel)
    try:
        g = _client()
    except Exception as e:
        return f"❌ Nicht angemeldet: {type(e).__name__}: {e}"
    existing = {}
    if replace_existing:
        try:
            for item in g.connectapi("/workout-service/workouts?start=0&limit=200&myWorkoutsOnly=true") or []:
                existing.setdefault(item.get("workoutName"), []).append(item.get("workoutId"))
        except Exception as e:
            return f"❌ Vorhandene Workouts nicht abrufbar: {type(e).__name__}: {e}"
    results = []
    for w in sel:
        for old_id in existing.get(w["name"], []):
            try:
                g.client.delete("connectapi", f"/workout-service/workout/{old_id}", api=True)
                results.append(f"♻️ {w['name']}: altes Workout {old_id} gelöscht")
            except Exception as e:
                results.append(f"❌ {w['name']}: altes Workout {old_id} nicht gelöscht ({type(e).__name__}: {e})")
        payload = make_payload(w["name"], w["steps"])
        try:
            resp = g.client.post("connectapi", "/workout-service/workout", api=True, json=payload)
            wid = resp.get("workoutId") if isinstance(resp, dict) else None
            results.append(f"✅ {w['name']} → ID {wid}")
        except Exception as e:
            results.append(f"❌ {w['name']}: {type(e).__name__}: {e}")
    ok = sum(1 for r in results if r.startswith("✅"))
    return f"{ok}/{len(sel)} Workouts angelegt:\n" + "\n".join(results)


@write_tool
def delete_workout(workout_id: str) -> str:
    """Löscht ein Workout anhand seiner ID aus Garmin Connect."""
    try:
        g = _client()
        g.client.delete("connectapi", f"/workout-service/workout/{workout_id}", api=True)
        return f"✅ Workout {workout_id} gelöscht."
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"


@write_tool
def schedule_workout(workout_id: str, date: str) -> str:
    """Legt ein Workout auf ein Datum (YYYY-MM-DD) im Garmin-Kalender."""
    try:
        g = _client()
        g.client.post("connectapi", f"/workout-service/schedule/{workout_id}",
                      api=True, json={"date": date})
        return f"✅ Workout {workout_id} für {date} eingeplant."
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"


if __name__ == "__main__":
    mcp.run()
