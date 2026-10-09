"""
Builds structured Garmin Connect running workouts from the plan in plan.json (Pace Lab).

Pure logic, no network access — so it can be tested offline.
The output is the JSON payload that the POST /workout-service/workout endpoint expects.
"""
import json
import os
import re

# ---------------------------------------------------------------------------
# Garmin constants
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
    """(targetType, valueOne, valueTwo, zoneNumber) for a target.
    target: None (no target) | HR zone dict | pace tuple."""
    if target is None:
        return TARGET_NO, None, None, None
    if isinstance(target, dict) and target.get("kind") == "hr":
        return TARGET_HR_ZONE, float(target["lo"]), float(target["hi"]), target["zone"]
    lo, hi = _pace_targets(target)
    return TARGET_PACE, lo, hi, None


# ---------------------------------------------------------------------------
# Step DTO builder
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
    """Collects steps with a running stepOrder, including inside repeats."""

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
# THE PLAN lives in plan.json in the training folder — weeks, sessions and, per
# session, a "workout" with steps. The Pace Lab app and this builder read the
# same file.
#
# Schema (details in the README, section "Plan schema"):
#   "workout": {"name": "6x800m", "steps": [
#       {"type": "warmup", "time": 600, "note": "Easy warm-up (by feel)"},
#       {"repeat": 6, "steps": [
#           {"type": "interval", "distance": 800, "pace": "Intervalle 800/1000 m", "note": "800 m brisk"},
#           {"type": "recovery", "time": 90, "note": "90 s easy jog"}]},
#       {"type": "cooldown", "time": 600, "note": "Easy cool-down (by feel)"}]}
#   type:  warmup | cooldown | interval | recovery | run (continuous segment)
#   end:   "distance" (meters) or "time" (seconds)
#   target: "pace" = name of a paceBand or "m:ss-m:ss"; "hr" = "lo-hi" (bpm,
#          optional "zone"); without a target = free, by feel.
# Name in Garmin: "{workoutPrefix} W{week:02d} · {name}", e.g. "PL W01 · 6x800m".
# ---------------------------------------------------------------------------
# Path to plan.json: PACELAB_PLAN (Pace Lab sets it in the .mcp.json of the training folder),
# otherwise plan.json in the working directory, otherwise next to this folder.
PLAN_PATH = (os.environ.get("PACELAB_PLAN")
             or next((p for p in (os.path.join(os.getcwd(), "plan.json"),) if os.path.exists(p)), None)
             or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plan.json"))

_STEP_TYPES = {"warmup": "warmup", "cooldown": "cooldown", "interval": "interval",
               "recovery": "recovery", "rest": "rest", "run": "other"}
_RANGE = re.compile(r"^\s*(\d{1,2}:\d{2})\s*[-–]\s*(\d{1,2}:\d{2})\s*$")


def load_plan(path=None):
    with open(path or PLAN_PATH, encoding="utf-8") as f:
        return json.load(f)


def _pace_range(text, bands):
    """'Steady' (name of a pace band) or '5:40-6:10' -> ('5:40', '6:10')."""
    value = bands.get(str(text).strip().lower(), str(text))
    m = _RANGE.match(value)
    if not m:
        raise ValueError(f"Unknown pace target {text!r}: name of a paceBand or 'm:ss-m:ss'")
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
            raise ValueError(f"Unknown step type {step.get('type')!r}")
        if "distance" in step:
            end, val = "distance", step["distance"]
        elif "time" in step:
            end, val = "time", step["time"]
        else:
            raise ValueError(f"Step without 'distance' or 'time': {step}")
        wb.add(stype, end, val, _step_target(step, bands), step.get("note"))


def workout_steps(workout, bands):
    """Garmin steps for a "workout" from plan.json."""
    wb = WB()
    _add_steps(wb, workout["steps"], bands)
    return wb.steps


def build_plan(path=None):
    """All workouts of the active plan: [{week, kind, name, steps, upload}] in plan order.
    Sessions without a "workout" (e.g. a race) are skipped. upload=False for easy
    runs, unless the plan sets "uploadEasyRuns": true."""
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
# Human-readable summary (for a preview without network)
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
    print(f"{len(plan)} workouts generated.\n")
    for w in plan:
        print(f"### {w['name']}  (week {w['week']}, {w['kind']})")
        for line in describe_steps(w["steps"]):
            print(line)
        print()
    # Sample payload for checking
    print("--- Beispiel-Payload (erstes Workout) ---")
    print(json.dumps(make_payload(plan[0]["name"], plan[0]["steps"]), indent=2, ensure_ascii=False))
