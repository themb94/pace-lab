"""
Baut strukturierte Garmin-Connect-Laufworkouts aus dem Plan in plan.json (Pace Lab).

Reine Logik, keine Netzwerkzugriffe — dadurch offline testbar.
Ausgabe ist das JSON-Payload, das der Endpunkt POST /workout-service/workout erwartet.
"""
import json
import os
import re

# ---------------------------------------------------------------------------
# Garmin-Konstanten
# ---------------------------------------------------------------------------
SPORT = {"sportTypeId": 1, "sportTypeKey": "running", "displayOrder": 1}


def _stype(key, i):
    return {"stepTypeId": i, "stepTypeKey": key, "displayOrder": i}


STEP_TYPE = {
    "warmup":   _stype("warmup", 1),
    "cooldown": _stype("cooldown", 2),
    "interval": _stype("interval", 3),
    "recovery": _stype("recovery", 4),
    "rest":     _stype("rest", 5),
    "repeat":   _stype("repeat", 6),
    "other":    _stype("other", 7),
}

END_COND = {
    "lap.button": {"conditionTypeId": 1, "conditionTypeKey": "lap.button", "displayOrder": 1, "displayable": True},
    "time":       {"conditionTypeId": 2, "conditionTypeKey": "time", "displayOrder": 2, "displayable": True},
    "distance":   {"conditionTypeId": 3, "conditionTypeKey": "distance", "displayOrder": 3, "displayable": True},
    "iterations": {"conditionTypeId": 7, "conditionTypeKey": "iterations", "displayOrder": 7, "displayable": False},
}

TARGET_NO = {"workoutTargetTypeId": 1, "workoutTargetTypeKey": "no.target", "displayOrder": 1}
TARGET_PACE = {"workoutTargetTypeId": 6, "workoutTargetTypeKey": "pace.zone", "displayOrder": 6}
TARGET_HR_ZONE = {"workoutTargetTypeId": 4, "workoutTargetTypeKey": "heart.rate.zone", "displayOrder": 4}

def _mps(p):
    m, s = p.split(":")
    return 1000.0 / (int(m) * 60 + int(s))


def _pace_targets(pace):
    a, b = _mps(pace[0]), _mps(pace[1])
    return (min(a, b), max(a, b))


def _target_block(target):
    """(targetType, valueOne, valueTwo, zoneNumber) für ein Ziel.
    target: None (kein Ziel) | HF-Zonen-Dict | Pace-Tupel."""
    if target is None:
        return TARGET_NO, None, None, None
    if isinstance(target, dict) and target.get("kind") == "hr":
        return TARGET_HR_ZONE, float(target["lo"]), float(target["hi"]), target["zone"]
    lo, hi = _pace_targets(target)
    return TARGET_PACE, lo, hi, None


# ---------------------------------------------------------------------------
# Step-DTO-Builder
# ---------------------------------------------------------------------------
def _exec_dto(order, stype, end, val, target=None, desc=None, child=None):
    ttype, v1, v2, zone = _target_block(target)
    return {
        "type": "ExecutableStepDTO",
        "stepId": None,
        "stepOrder": order,
        "stepType": STEP_TYPE[stype],
        "childStepId": child,
        "description": desc,
        "endCondition": END_COND[end],
        "endConditionValue": float(val),
        "endConditionCompare": None,
        "targetType": ttype,
        "targetValueOne": v1,
        "targetValueTwo": v2,
        "zoneNumber": zone,
    }


def _repeat_dto(order, n, gid, children):
    return {
        "type": "RepeatGroupDTO",
        "stepId": None,
        "stepOrder": order,
        "stepType": STEP_TYPE["repeat"],
        "childStepId": gid,
        "numberOfIterations": n,
        "smartRepeat": False,
        "endCondition": END_COND["iterations"],
        "endConditionValue": float(n),
        "workoutSteps": children,
    }


class WB:
    """Sammelt Steps mit fortlaufender stepOrder, auch innerhalb von Wiederholungen."""

    def __init__(self):
        self.order = 0
        self.cg = 0
        self.steps = []
        self._child = None

    def add(self, stype, end, val, pace=None, desc=None):
        self.order += 1
        self.steps.append(_exec_dto(self.order, stype, end, val, pace, desc, self._child))

    def repeat(self, n, fn):
        self.order += 1
        ro = self.order
        self.cg += 1
        gid = self.cg
        outer_steps, outer_child = self.steps, self._child
        self.steps, self._child = [], gid
        fn()
        children = self.steps
        self.steps, self._child = outer_steps, outer_child
        self.steps.append(_repeat_dto(ro, n, gid, children))


def make_payload(name, steps):
    return {
        "sportType": SPORT,
        "subSportType": None,
        "workoutName": name,
        "estimatedDistanceUnit": {"unitKey": None},
        "workoutSegments": [
            {"segmentOrder": 1, "sportType": SPORT, "workoutSteps": steps}
        ],
    }


# ---------------------------------------------------------------------------
# DER PLAN steht in plan.json im Trainingsordner — Wochen, Einheiten und je
# Einheit ein "workout" mit Schritten. Die App Pace Lab und dieser Builder lesen
# dieselbe Datei.
#
# Schema (Details in der README, Abschnitt "Plan-Schema"):
#   "workout": {"name": "6x800m", "steps": [
#       {"type": "warmup", "time": 600, "note": "Locker einlaufen (nach Gefühl)"},
#       {"repeat": 6, "steps": [
#           {"type": "interval", "distance": 800, "pace": "Intervalle 800/1000 m", "note": "800 m zügig"},
#           {"type": "recovery", "time": 90, "note": "90 s locker traben"}]},
#       {"type": "cooldown", "time": 600, "note": "Locker auslaufen (nach Gefühl)"}]}
#   type:  warmup | cooldown | interval | recovery | run (durchgehender Abschnitt)
#   Ende:  "distance" (Meter) oder "time" (Sekunden)
#   Ziel:  "pace" = Name eines paceBands oder "m:ss-m:ss"; "hr" = "lo-hi" (bpm,
#          optional "zone"); ohne Ziel = frei nach Gefühl.
# Name in Garmin: "{workoutPrefix} W{Woche:02d} · {name}", z. B. "PL W01 · 6x800m".
# ---------------------------------------------------------------------------
# Pfad zu plan.json: PACELAB_PLAN (setzt Pace Lab in der .mcp.json des Trainingsordners),
# sonst plan.json im Arbeitsverzeichnis, sonst neben diesem Ordner.
PLAN_PATH = (os.environ.get("PACELAB_PLAN") or os.environ.get("LAUFPLAN_PLAN")
             or next((p for p in (os.path.join(os.getcwd(), "plan.json"),) if os.path.exists(p)), None)
             or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plan.json"))

_STEP_TYPES = {"warmup": "warmup", "cooldown": "cooldown", "interval": "interval",
               "recovery": "recovery", "rest": "rest", "run": "other"}
_RANGE = re.compile(r"^\s*(\d{1,2}:\d{2})\s*[-–]\s*(\d{1,2}:\d{2})\s*$")


def load_plan(path=None):
    with open(path or PLAN_PATH, encoding="utf-8") as f:
        return json.load(f)


def _pace_range(text, bands):
    """'Steady' (Name eines Pace-Bands) oder '5:40-6:10' -> ('5:40', '6:10')."""
    value = bands.get(str(text).strip().lower(), str(text))
    m = _RANGE.match(value)
    if not m:
        raise ValueError(f"Unbekanntes Pace-Ziel {text!r}: Name eines paceBands oder 'm:ss-m:ss'")
    return (m.group(1), m.group(2))


def _step_target(step, bands):
    if step.get("pace"):
        return _pace_range(step["pace"], bands)
    if step.get("hr"):
        lo, hi = (int(x) for x in re.split(r"\s*[-–]\s*", str(step["hr"]).strip()))
        return {"kind": "hr", "zone": step.get("zone"), "lo": lo, "hi": hi}
    return None


def _add_steps(wb, steps, bands):
    for step in steps:
        if "repeat" in step:
            wb.repeat(int(step["repeat"]), lambda inner=step["steps"]: _add_steps(wb, inner, bands))
            continue
        stype = _STEP_TYPES.get(step.get("type", "run"))
        if stype is None:
            raise ValueError(f"Unbekannter Schritt-Typ {step.get('type')!r}")
        if "distance" in step:
            end, val = "distance", step["distance"]
        elif "time" in step:
            end, val = "time", step["time"]
        else:
            raise ValueError(f"Schritt ohne 'distance' oder 'time': {step}")
        wb.add(stype, end, val, _step_target(step, bands), step.get("note"))


def workout_steps(workout, bands):
    """Garmin-Steps für ein "workout" aus plan.json."""
    wb = WB()
    _add_steps(wb, workout["steps"], bands)
    return wb.steps


def build_plan(path=None):
    """Alle Workouts des aktiven Plans: [{week, kind, name, steps, upload}] in Plan-Reihenfolge.
    Einheiten ohne "workout" (z. B. ein Wettkampf) werden übersprungen. upload=False für lockere
    Läufe, außer der Plan setzt "uploadEasyRuns": true."""
    plan = load_plan(path)
    upload_easy = bool(plan.get("uploadEasyRuns"))
    prefix = plan.get("workoutPrefix") or (plan.get("idPrefix") or "").upper()
    bands = {b["name"].strip().lower(): b["range"] for b in plan.get("paceBands") or []}
    P = []
    for week, w in enumerate(plan["weeks"], start=1):
        for s in w["sessions"]:
            workout = s.get("workout")
            if not workout:
                continue
            name = f"{prefix} W{week:02d} · {workout['name']}".strip()
            P.append({"week": week, "kind": s["type"], "name": name,
                      "steps": workout_steps(workout, bands),
                      "upload": s["type"] != "easy" or upload_easy})
    return P


# ---------------------------------------------------------------------------
# Menschenlesbare Zusammenfassung (für Preview ohne Netzwerk)
# ---------------------------------------------------------------------------
def _pace_str(pace):
    return f"{pace[0]}-{pace[1]}/km" if pace else "frei"


def describe_steps(steps, indent=0):
    lines = []
    pad = "    " * indent
    for s in steps:
        if s["type"] == "RepeatGroupDTO":
            lines.append(f"{pad}{s['numberOfIterations']}x:")
            lines.extend(describe_steps(s["workoutSteps"], indent + 1))
        else:
            key = s["stepType"]["stepTypeKey"]
            ec = s["endCondition"]["conditionTypeKey"]
            val = s["endConditionValue"]
            if ec == "distance":
                amount = f"{val/1000:.2f} km" if val >= 1000 else f"{int(val)} m"
            elif ec == "time":
                amount = f"{int(val//60)}:{int(val % 60):02d} min" if val >= 60 else f"{int(val)} s"
            else:
                amount = ec
            target_key = s["targetType"]["workoutTargetTypeKey"]
            tv1, tv2 = s.get("targetValueOne"), s.get("targetValueTwo")
            tgt = ""
            if target_key == "pace.zone" and tv1 and tv2:
                p1 = _sec_to_pace(1000.0 / tv2)  # schneller
                p2 = _sec_to_pace(1000.0 / tv1)  # langsamer
                tgt = f" @ {p1}-{p2}/km"
            elif target_key == "heart.rate.zone":
                z = s.get("zoneNumber")
                tgt = f" @ HF Zone {z} ({int(tv1)}-{int(tv2)} bpm)" if tv1 and tv2 else f" @ HF Zone {z}"
            lines.append(f"{pad}- {key}: {amount}{tgt}")
    return lines


def _sec_to_pace(sec_per_km):
    m = int(sec_per_km // 60)
    s = int(round(sec_per_km % 60))
    if s == 60:
        m, s = m + 1, 0
    return f"{m}:{s:02d}"


if __name__ == "__main__":
    import json
    plan = build_plan()
    print(f"{len(plan)} Workouts erzeugt.\n")
    for w in plan:
        print(f"### {w['name']}  (Woche {w['week']}, {w['kind']})")
        for line in describe_steps(w["steps"]):
            print(line)
        print()
    # Beispiel-Payload zur Kontrolle
    print("--- Beispiel-Payload (erstes Workout) ---")
    print(json.dumps(make_payload(plan[0]["name"], plan[0]["steps"]), indent=2, ensure_ascii=False))
