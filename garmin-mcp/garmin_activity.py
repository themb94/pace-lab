"""
Turns Garmin Connect activity data into the compact shape Pace Lab reads (get_activity_data and
list_activities of server.py) — including the running dynamics ("Laufeffizienz" in Garmin's German
apps): stride length, ground contact time and its left/right balance, vertical oscillation and
vertical ratio. They need a watch or accessory that measures them (e.g. HRM-Pro, Running Dynamics
Pod or wrist-based running dynamics); without one the keys are simply missing.

No network and no packages — the functions take the client or the raw dictionaries.
"""

SUMMARY_KEYS = [
    "startTimeLocal", "distance", "duration", "movingDuration",
    "elapsedDuration", "elevationGain", "elevationLoss", "averageSpeed",
    "maxSpeed", "averageHR", "maxHR", "averageRunCadence",
    "maxRunCadence", "averageTemperature", "minTemperature",
    "maxTemperature", "averagePower", "maxPower", "trainingEffect",
    "anaerobicTrainingEffect", "trainingEffectLabel", "activityTrainingLoad",
    "directWorkoutFeel", "directWorkoutRpe", "differenceBodyBattery",
]

LAP_KEYS = [
    "lapIndex", "distance", "duration", "movingDuration", "elapsedDuration",
    "elevationGain", "elevationLoss", "averageSpeed", "maxSpeed",
    "averageHR", "maxHR", "averageRunCadence", "maxRunCadence",
    "averagePower", "maxPower", "averageTemperature", "intensityType",
]

# Running dynamics in the result → where Garmin keeps them: the activity summary and its laps use the
# first names, the activity list the "avg…" ones. Units in the result: strideLength cm,
# groundContactTime ms, groundContactBalance % on the left foot, verticalOscillation cm, verticalRatio %.
DYNAMICS = {
    "strideLength": ("strideLength", "avgStrideLength"),
    "groundContactTime": ("groundContactTime", "avgGroundContactTime"),
    "groundContactBalance": ("groundContactBalanceLeft", "avgGroundContactBalance", "groundContactBalance"),
    "verticalOscillation": ("verticalOscillation", "avgVerticalOscillation"),
    "verticalRatio": ("verticalRatio", "avgVerticalRatio"),
}


def _pick(sources, keys):
    for source in sources:
        for key in keys:
            value = (source or {}).get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0:
                return float(value)
    return None


def running_dynamics(*sources):
    """Running dynamics from the given dictionaries (the first one that has a value wins), in the units
    above. Lengths Garmin reports in meters are converted to centimeters."""
    result = {}
    for name, keys in DYNAMICS.items():
        value = _pick(sources, keys)
        if value is None:
            continue
        if name == "strideLength" and value < 3:
            value *= 100
        if name == "verticalOscillation" and value < 1:
            value *= 100
        result[name] = round(value, 1)
    return result


def listed_activity(client, activity_id, start_local):
    """The activity's entry in Garmin's activity list (it carries the running dynamics under other names)."""
    day = str(start_local or "")[:10]
    if len(day) != 10:
        return None
    for entry in client.get_activities_by_date(day, day) or []:
        if str(entry.get("activityId")) == str(activity_id):
            return entry
    return None


def activity_data(client, activity_id):
    """get_activity_data: summary, kilometer/workout laps and Garmin weather, each with the running
    dynamics if the watch measured them. Deliberately without GPS track and per-second series."""
    activity = client.get_activity(activity_id)
    split_data = client.get_activity_splits(activity_id)
    try:
        weather = client.get_activity_weather(activity_id)
    except Exception as e:
        weather = {"error": f"{type(e).__name__}: {e}"}

    raw = activity.get("summaryDTO") or {}
    summary = {k: raw.get(k) for k in SUMMARY_KEYS}
    dynamics = running_dynamics(raw)
    if len(dynamics) < len(DYNAMICS):
        # The activity summary doesn't name every value the way the list does — fill in from there.
        try:
            dynamics = running_dynamics(raw, listed_activity(client, activity_id, raw.get("startTimeLocal")))
        except Exception:
            pass
    summary.update(dynamics)

    laps = [
        {**{k: lap.get(k) for k in LAP_KEYS}, **running_dynamics(lap)}
        for lap in (split_data.get("lapDTOs") or [])
        if (lap.get("distance") or 0) >= 100
    ]
    return {
        "source": "garmin",
        "activityId": activity.get("activityId"),
        "activityName": activity.get("activityName"),
        "activityType": (activity.get("activityTypeDTO") or {}).get("typeKey"),
        "summary": summary,
        "laps": laps,
        "weather": weather,
    }


def compact_activity(a):
    """list_activities: one activity in short form, with its running dynamics if measured."""
    entry = {
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
    }
    dynamics = running_dynamics(a)
    if dynamics:
        entry["runningDynamics"] = dynamics
    return entry
