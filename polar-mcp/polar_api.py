"""
Polar AccessLink (Polar's official API) for Pace Lab — sign-in, requests and the conversion of a
Polar training session into the same shape the Garmin server delivers (summary + laps), so the app
and the coach treat both watches alike.

Everything except `request` and the sign-in is pure logic and can be tested offline (test_polar.py).

API: https://www.polar.com/accesslink-api/ — exercises are read-only; Polar only passes on training
sessions that were synced to Polar Flow in the last 30 days and after the user linked the client.
"""
import base64
import json
import os
import re
import secrets
import threading
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, HTTPServer
from socket import AF_INET6

# The URLs can be overridden for tests (a local fake API); normally they are Polar's.
API_BASE = os.environ.get("POLAR_API_BASE", "https://www.polaraccesslink.com")
AUTH_URL = os.environ.get("POLAR_AUTH_URL", "https://flow.polar.com/oauth2/authorization")
TOKEN_URL = os.environ.get("POLAR_TOKEN_URL", "https://polarremote.com/v2/oauth2/token")
# Must be registered exactly like this for the client at admin.polaraccesslink.com.
REDIRECT_PORT = int(os.environ.get("POLAR_REDIRECT_PORT", "8721"))
REDIRECT_PATH = "/pacelab/callback"
REDIRECT_URI = f"http://localhost:{REDIRECT_PORT}{REDIRECT_PATH}"

TOKENSTORE = os.path.expanduser(os.environ.get("POLAR_TOKENSTORE", "~/.pacelab-polar"))
TOKEN_FILE = os.path.join(TOKENSTORE, "polar.json")

# Sample types of an exercise (AccessLink appendix "Exercise sample types").
HEART_RATE, SPEED, ALTITUDE, RUNNING_CADENCE, TEMPERATURE, DISTANCE = "0", "1", "3", "8", "9", "10"


class PolarError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------------------
# Stored sign-in (client and token of this profile)
# ---------------------------------------------------------------------------
def load_account():
    try:
        with open(TOKEN_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_account(account):
    os.makedirs(TOKENSTORE, exist_ok=True)
    os.chmod(TOKENSTORE, 0o700)
    tmp = TOKEN_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(account, f, indent=2)
    os.replace(tmp, TOKEN_FILE)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def request(method, url, token=None, basic=None, form=None, body=None, accept="application/json", timeout=60):
    """Returns (status, bytes). Raises PolarError for HTTP errors (with status)."""
    headers = {"Accept": accept, "User-Agent": "PaceLab"}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if basic:
        headers["Authorization"] = "Basic " + base64.b64encode(f"{basic[0]}:{basic[1]}".encode()).decode()
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        raise PolarError(f"HTTP {e.code} {e.reason}: {detail}".strip(), e.code) from None
    except urllib.error.URLError as e:
        raise PolarError(f"{e.reason}") from None


def api_get(path, token, accept="application/json"):
    status, data = request("GET", API_BASE + path, token=token, accept=accept)
    if status == 204 or not data:
        return None
    return data if accept != "application/json" else json.loads(data)


# ---------------------------------------------------------------------------
# Sign-in: OAuth2 authorization code flow with a short-lived local callback
# ---------------------------------------------------------------------------
class LoginFlow:
    """Waits on localhost for Polar's redirect after the user approved access in the browser."""

    def __init__(self, client_id, client_secret, page_text):
        self.client_id = client_id
        self.client_secret = client_secret
        self.state = secrets.token_urlsafe(16)
        self.page_text = page_text
        self.result = None           # ("code", value) or ("error", message)
        self.done = threading.Event()
        self.servers = []

    @property
    def url(self):
        return AUTH_URL + "?" + urllib.parse.urlencode({
            "response_type": "code", "client_id": self.client_id,
            "redirect_uri": REDIRECT_URI, "scope": "accesslink.read_all", "state": self.state,
        })

    def start(self):
        flow = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path != REDIRECT_PATH:
                    self.send_response(404)
                    self.end_headers()
                    return
                query = urllib.parse.parse_qs(parsed.query)
                if query.get("state", [""])[0] != flow.state:
                    flow.finish(("error", "state mismatch"))
                elif "code" in query:
                    flow.finish(("code", query["code"][0]))
                else:
                    flow.finish(("error", query.get("error", ["no code"])[0]))
                page = f"<!doctype html><meta charset=utf-8><title>Pace Lab</title>" \
                       f"<body style='font:16px -apple-system;padding:40px'>{flow.page_text}</body>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(page.encode())

            def log_message(self, *args):
                pass

        class Server6(HTTPServer):
            address_family = AF_INET6

        # "localhost" can mean IPv4 or IPv6 in the browser — listen on both loopback addresses.
        for cls, host in ((HTTPServer, "127.0.0.1"), (Server6, "::1")):
            try:
                server = cls((host, REDIRECT_PORT), Handler)
            except OSError:
                continue
            self.servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        if not self.servers:
            raise PolarError(f"Port {REDIRECT_PORT} is in use.")

    def finish(self, result):
        if self.result is None:
            self.result = result
        self.done.set()

    def stop(self):
        for server in self.servers:
            threading.Thread(target=server.shutdown, daemon=True).start()
        self.servers = []

    def wait(self, timeout):
        """Exchanges the code for a token and registers the user with the client. Returns the account."""
        try:
            if not self.done.wait(timeout):
                raise PolarError("timeout")
        finally:
            self.stop()
        kind, value = self.result
        if kind != "code":
            raise PolarError(value)
        _, data = request("POST", TOKEN_URL, basic=(self.client_id, self.client_secret),
                          form={"grant_type": "authorization_code", "code": value, "redirect_uri": REDIRECT_URI})
        token = json.loads(data)
        access, user_id = token.get("access_token"), token.get("x_user_id")
        if not access or user_id is None:
            raise PolarError(f"unexpected token response: {list(token)}")
        # Register the user with this client (409 = already registered — fine).
        try:
            request("POST", API_BASE + "/v3/users", token=access, body={"member-id": f"pacelab-{user_id}"})
        except PolarError as e:
            if e.status != 409:
                raise
        return {"client_id": self.client_id, "client_secret": self.client_secret,
                "access_token": access, "user_id": user_id, "expires_in": token.get("expires_in")}


# ---------------------------------------------------------------------------
# Conversion: Polar exercise → Pace Lab's run shape
# ---------------------------------------------------------------------------
def field(obj, name, default=None):
    """Polar mixes snake_case and kebab-case — accepts both."""
    if not isinstance(obj, dict):
        return default
    for key in (name, name.replace("_", "-"), name.replace("-", "_")):
        if key in obj and obj[key] is not None:
            return obj[key]
    return default


def iso_seconds(text):
    """ISO 8601 duration ("PT1H2M3.5S") → seconds."""
    m = re.fullmatch(r"P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?)?", str(text or ""))
    if not m:
        return None
    d, h, mi, s = (float(x) if x else 0.0 for x in m.groups())
    return d * 86400 + h * 3600 + mi * 60 + s


def is_running(exercise):
    sport = str(field(exercise, "sport", "")).upper()
    detail = str(field(exercise, "detailed_sport_info", "")).upper()
    return sport == "RUNNING" or "RUNNING" in detail


_NAMES = {
    "TRAIL_RUNNING": ("Trail run", "Traillauf"),
    "TREADMILL_RUNNING": ("Treadmill run", "Laufband"),
    "INDOOR_RUNNING": ("Indoor run", "Indoor-Lauf"),
    "TRACK_AND_FIELD_RUNNING": ("Track run", "Bahnlauf"),
    "CROSS_COUNTRY_RUNNING": ("Cross-country run", "Crosslauf"),
}


def activity_name(exercise, lang):
    """Polar sessions have no name — "Lauf · 07:30" from the sport and the start time."""
    en, de = _NAMES.get(str(field(exercise, "detailed_sport_info", "")).upper(), ("Run", "Lauf"))
    start = str(field(exercise, "start_time", ""))
    clock = start[11:16] if len(start) >= 16 else ""
    base = de if lang == "de" else en
    return f"{base} · {clock}" if clock else base


def compact(exercise, lang):
    """One line of list_activities — the same keys as the Garmin server."""
    return {
        "activityId": field(exercise, "id"),
        "activityName": activity_name(exercise, lang),
        "startTimeLocal": str(field(exercise, "start_time", "")).replace("T", " "),
        "activityType": str(field(exercise, "detailed_sport_info") or field(exercise, "sport") or "").lower(),
        "distance_m": field(exercise, "distance"),
        "duration_s": iso_seconds(field(exercise, "duration")),
        "averageHR": field(field(exercise, "heart_rate", {}), "average"),
        "maxHR": field(field(exercise, "heart_rate", {}), "maximum"),
        "trainingLoad": field(exercise, "training_load"),
        "device": field(exercise, "device"),
    }


def _values(text):
    out = []
    for part in str(text or "").split(","):
        part = part.strip()
        try:
            out.append(float(part) if part and part.lower() != "null" else None)
        except ValueError:
            out.append(None)
    return out


def samples_by_type(exercise):
    """{type: (recording_rate_seconds, [values])}"""
    result = {}
    for sample in field(exercise, "samples", []) or []:
        kind = str(field(sample, "sample_type", ""))
        rate = field(sample, "recording_rate") or 1
        result[kind] = (float(rate), _values(field(sample, "data", "")))
    return result


def points_from_samples(samples):
    """Per-sample points (t seconds, distance m, hr, altitude) — the time axis comes from the distance samples."""
    if DISTANCE not in samples:
        return []
    rate, distance = samples[DISTANCE]

    def at(kind, t):
        if kind not in samples:
            return None
        r, values = samples[kind]
        i = int(round(t / r)) if r else 0
        return values[i] if 0 <= i < len(values) else None

    return [(i * rate, d, at(HEART_RATE, i * rate), at(ALTITUDE, i * rate)) for i, d in enumerate(distance)]


_TCX = "{http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2}"


def points_from_tcx(xml_bytes):
    """Fallback without samples: trackpoints of the TCX export."""
    from datetime import datetime
    root = ET.fromstring(xml_bytes)
    points, start = [], None
    for tp in root.iter(_TCX + "Trackpoint"):
        time = tp.findtext(_TCX + "Time")
        dist = tp.findtext(_TCX + "DistanceMeters")
        if not time or dist is None:
            continue
        stamp = datetime.fromisoformat(time.replace("Z", "+00:00"))
        start = start or stamp
        hr = tp.findtext(f"{_TCX}HeartRateBpm/{_TCX}Value")
        alt = tp.findtext(_TCX + "AltitudeMeters")
        points.append(((stamp - start).total_seconds(), float(dist),
                       float(hr) if hr else None, float(alt) if alt else None))
    return points


def kilometer_laps(points):
    """Kilometer laps from (t, distance, hr, altitude) points — the watch's own laps depend on its
    settings, so Pace Lab always splits per kilometer (like Garmin's auto lap). The rest ≥ 100 m
    becomes a last, shorter lap."""
    points = [p for p in points if p[1] is not None]
    if len(points) < 2:
        return []
    laps, lap_start_t, lap_start_d, mark = [], points[0][0], points[0][1], 1000.0
    lap_hr = []

    def close(end_t, end_d):
        hrs = [h for h in lap_hr if h]
        seconds = end_t - lap_start_t
        laps.append({
            "lapIndex": len(laps) + 1,
            "distance": round(end_d - lap_start_d, 1),
            "duration": round(seconds, 1),
            "movingDuration": round(seconds, 1),
            "averageHR": round(sum(hrs) / len(hrs)) if hrs else None,
            "maxHR": round(max(hrs)) if hrs else None,
            "averageSpeed": round((end_d - lap_start_d) / seconds, 3) if seconds > 0 else None,
        })

    previous = points[0]
    for point in points[1:]:
        t, d, hr, _ = point
        while d >= mark:
            # Time at exactly this kilometer, interpolated between the two samples.
            pt, pd = previous[0], previous[1]
            end_t = pt + (t - pt) * ((mark - pd) / (d - pd)) if d > pd else t
            close(end_t, mark)
            lap_start_t, lap_start_d, lap_hr = end_t, mark, []
            mark += 1000.0
        lap_hr.append(hr)
        previous = point
    last_t, last_d = points[-1][0], points[-1][1]
    if last_d - lap_start_d >= 100:
        close(last_t, last_d)
    return laps


def elevation_gain(altitudes, threshold=2.0):
    """Ascent with a small hysteresis — GPS altitude is noisy."""
    values = [a for a in altitudes if a is not None]
    if not values:
        return None
    gain, ref = 0.0, values[0]
    for a in values[1:]:
        if a >= ref + threshold:
            gain += a - ref
            ref = a
        elif a < ref:
            ref = a
    return round(gain)


def _mean(values, positive=False):
    values = [v for v in values if v is not None and (v > 0 or not positive)]
    return sum(values) / len(values) if values else None


def activity_data(exercise, lang, tcx=None):
    """get_activity_data: summary, kilometer laps, heart-rate zones — the same keys as the Garmin server
    (summary.startTimeLocal, distance, movingDuration, averageHR, maxHR, elevationGain, averageRunCadence
    in steps of both feet per minute, averageTemperature)."""
    samples = samples_by_type(exercise)
    points = points_from_samples(samples)
    if not points and tcx:
        points = points_from_tcx(tcx)
    duration = iso_seconds(field(exercise, "duration"))
    distance = field(exercise, "distance")
    heart = field(exercise, "heart_rate", {})
    altitudes = samples.get(ALTITUDE, (1, []))[1] or [p[3] for p in points]
    cadence = _mean(samples.get(RUNNING_CADENCE, (1, []))[1], positive=True)
    temperature = _mean(samples.get(TEMPERATURE, (1, []))[1])
    zones = [{
        "zone": field(z, "index"),
        "lowerBpm": field(z, "lower_limit"),
        "upperBpm": field(z, "upper_limit"),
        "seconds": iso_seconds(field(z, "in_zone")),
    } for z in field(exercise, "heart_rate_zones", []) or []]
    return {
        "source": "polar",
        "activityId": field(exercise, "id"),
        "activityName": activity_name(exercise, lang),
        "activityType": str(field(exercise, "detailed_sport_info") or field(exercise, "sport") or "").lower(),
        "device": field(exercise, "device"),
        "summary": {
            "startTimeLocal": str(field(exercise, "start_time", "")).replace("T", " "),
            "distance": distance,
            "duration": duration,
            "movingDuration": duration,
            "averageSpeed": round(distance / duration, 3) if distance and duration else None,
            "averageHR": field(heart, "average"),
            "maxHR": field(heart, "maximum"),
            "elevationGain": elevation_gain(altitudes),
            "averageRunCadence": round(cadence) if cadence else None,
            "averageTemperature": round(temperature, 1) if temperature is not None else None,
            "calories": field(exercise, "calories"),
            "trainingLoad": field(exercise, "training_load"),
            "runningIndex": field(exercise, "running_index"),
        },
        "laps": kilometer_laps(points),
        "heartRateZones": zones,
        "note": "Laps are kilometer splits computed from the watch's samples (Polar passes on no laps).",
    }
