"""
The plan's workouts (plan.json) as Polar phased training targets — to enter in Polar Flow by hand.
Polar doesn't let other apps put training targets on the watch, so this only describes them.

Polar phases have a name, a length (time or distance) and an intensity given as a zone of the sport
profile (heart rate or speed/pace). Pace Lab's exact ranges are shown so the right zone can be picked.
Pure logic, no network.
"""
import json
import os
import re

PLAN_PATH = (os.environ.get("PACELAB_PLAN")
             or os.path.join(os.getcwd(), "plan.json"))

_RANGE = re.compile(r"^\s*(\d{1,2}:\d{2})\s*[-–]\s*(\d{1,2}:\d{2})\s*$")

_PHASE = {
    "warmup": ("Warm-up", "Aufwärmen"),
    "cooldown": ("Cool-down", "Auslaufen"),
    "interval": ("Work", "Belastung"),
    "recovery": ("Recovery", "Erholung"),
    "rest": ("Rest", "Pause"),
    "run": ("Run", "Lauf"),
}


def load_plan(path=None):
    with open(path or PLAN_PATH, encoding="utf-8") as f:
        return json.load(f)


def _length(step, de):
    if "distance" in step:
        m = float(step["distance"])
        return f"{m / 1000:.2f} km".replace(".", "," if de else ".") if m >= 1000 else f"{int(m)} m"
    seconds = int(step.get("time", 0))
    return f"{seconds // 60}:{seconds % 60:02d} min" if seconds >= 60 else f"{seconds} s"


def _intensity(step, bands, de):
    if step.get("pace"):
        value = bands.get(str(step["pace"]).strip().lower(), str(step["pace"]))
        m = _RANGE.match(value)
        pace = f"{m.group(1)}–{m.group(2)}/km" if m else value
        return (f"Pace {pace} → passende Pace-Zone wählen" if de
                else f"pace {pace} → pick the matching pace zone")
    if step.get("hr"):
        zone = step.get("zone")
        rng = str(step["hr"]).replace("-", "–")
        if zone:
            return f"HF-Zone {zone} ({rng} bpm)" if de else f"heart-rate zone {zone} ({rng} bpm)"
        return f"HF {rng} bpm → passende HF-Zone" if de else f"HR {rng} bpm → matching heart-rate zone"
    return "frei (nach Gefühl)" if de else "free (by feel)"


def phases(steps, bands, de, depth=0):
    """Text lines for the phases, repeats indented."""
    lines, pad = [], "   " * depth
    for step in steps:
        if "repeat" in step:
            lines.append(f"{pad}{step['repeat']}× {'wiederholen' if de else 'repeat'}:")
            lines.extend(phases(step.get("steps", []), bands, de, depth + 1))
            continue
        en, ger = _PHASE.get(step.get("type", "run"), _PHASE["run"])
        note = f" — {step['note']}" if step.get("note") else ""
        lines.append(f"{pad}• {ger if de else en}: {_length(step, de)}, {_intensity(step, bands, de)}{note}")
    return lines


def week_targets(week, lang="en", path=None):
    """The week's sessions with a workout as Polar phases (easy runs only with "uploadEasyRuns")."""
    plan = load_plan(path)
    de = lang == "de"
    weeks = plan.get("weeks") or []
    if not 1 <= week <= len(weeks):
        return None
    prefix = plan.get("workoutPrefix") or (plan.get("idPrefix") or "").upper()
    bands = {b["name"].strip().lower(): b["range"] for b in plan.get("paceBands") or []}
    upload_easy = bool(plan.get("uploadEasyRuns"))
    out = []
    for session in weeks[week - 1].get("sessions", []):
        workout = session.get("workout")
        if not workout or (session.get("type") == "easy" and not upload_easy):
            continue
        name = f"{prefix} W{week:02d} · {workout['name']}".strip()
        out.append({"name": name, "type": session.get("type"), "dist": session.get("dist"),
                    "phases": phases(workout.get("steps", []), bands, de)})
    return out
