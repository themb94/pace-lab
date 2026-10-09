"""
Offline tests for the Polar server: conversion of training sessions, kilometer laps, plan as phases
and the sign-in against a local fake of Polar's token and user endpoints.

Run: python3 -m unittest test_polar   (in this folder; needs no packages)
"""
import json
import os
import socket
import tempfile
import threading
import unittest
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


FAKE_PORT = free_port()
os.environ["POLAR_API_BASE"] = f"http://127.0.0.1:{FAKE_PORT}"
os.environ["POLAR_TOKEN_URL"] = f"http://127.0.0.1:{FAKE_PORT}/token"
os.environ["POLAR_REDIRECT_PORT"] = str(free_port())
os.environ["POLAR_TOKENSTORE"] = tempfile.mkdtemp()

import polar_api as api  # noqa: E402  (after the environment is set)
from polar_targets import week_targets  # noqa: E402


def exercise(**extra):
    base = {
        "id": "2AC312F", "start_time": "2026-10-07T07:30:00", "duration": "PT30M30S",
        "distance": 5100, "heart_rate": {"average": 150, "maximum": 172}, "sport": "RUNNING",
        "detailed_sport_info": "RUNNING", "device": "Polar Ignite 3",
    }
    base.update(extra)
    return base


class Conversion(unittest.TestCase):
    def test_duration(self):
        self.assertEqual(api.iso_seconds("PT1H2M3.5S"), 3723.5)
        self.assertEqual(api.iso_seconds("PT45M"), 2700)
        self.assertIsNone(api.iso_seconds("garbage"))

    def test_running_filter(self):
        self.assertTrue(api.is_running(exercise(sport="OTHER", detailed_sport_info="TRAIL_RUNNING")))
        self.assertFalse(api.is_running(exercise(sport="CYCLING", detailed_sport_info="ROAD_BIKING")))

    def test_compact_has_garmin_keys(self):
        row = api.compact(exercise(), "de")
        self.assertEqual(row["activityId"], "2AC312F")
        self.assertEqual(row["activityName"], "Lauf · 07:30")
        self.assertEqual(row["startTimeLocal"], "2026-10-07 07:30:00")
        self.assertEqual(row["distance_m"], 5100)
        self.assertEqual(row["duration_s"], 1830)
        self.assertEqual(row["averageHR"], 150)

    def test_kilometer_laps_from_samples(self):
        # 1 sample per second at exactly 3 m/s for 5100 m → five 1000 m laps of 333.3 s, a 100 m rest.
        seconds = 1700
        distance = ",".join(str(3 * i) for i in range(seconds + 1))
        hr = ",".join("140" if i < 1000 else "160" for i in range(seconds + 1))
        alt = ",".join(str(100 + (i // 100) * 3) for i in range(seconds + 1))
        data = api.activity_data(exercise(samples=[
            {"recording-rate": 1, "sample-type": "10", "data": distance},
            {"recording-rate": 1, "sample-type": "0", "data": hr},
            {"recording-rate": 1, "sample-type": "3", "data": alt},
            {"recording-rate": 1, "sample-type": "8", "data": "172,174,0,170"},
        ], heart_rate_zones=[{"index": 1, "lower-limit": 110, "upper-limit": 130, "in-zone": "PT4M"}]), "en")
        laps = data["laps"]
        self.assertEqual(len(laps), 6)
        self.assertEqual(laps[0]["distance"], 1000)
        self.assertAlmostEqual(laps[0]["duration"], 333.3, places=1)
        self.assertEqual(laps[0]["averageHR"], 140)
        self.assertEqual(laps[4]["averageHR"], 160)
        self.assertEqual(laps[5]["distance"], 100)
        summary = data["summary"]
        self.assertEqual(summary["averageRunCadence"], 172)
        self.assertEqual(summary["elevationGain"], 51)
        self.assertEqual(summary["movingDuration"], 1830)
        self.assertEqual(data["heartRateZones"][0]["seconds"], 240)

    def test_laps_from_tcx(self):
        ns = "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
        points = "".join(
            f"<Trackpoint><Time>2026-10-07T07:{30 + i // 60:02d}:{i % 60:02d}Z</Time>"
            f"<DistanceMeters>{i * 4}</DistanceMeters><HeartRateBpm><Value>150</Value></HeartRateBpm></Trackpoint>"
            for i in range(0, 600))
        tcx = f'<TrainingCenterDatabase xmlns="{ns}"><Activities><Activity><Lap><Track>{points}</Track></Lap></Activity></Activities></TrainingCenterDatabase>'
        data = api.activity_data(exercise(), "en", tcx=tcx.encode())
        self.assertEqual([round(lap["duration"]) for lap in data["laps"]], [250, 250, 99])
        self.assertEqual(data["laps"][1]["averageHR"], 150)


class Plan(unittest.TestCase):
    def test_week_as_phases(self):
        plan = {
            "idPrefix": "b1", "workoutPrefix": "PL",
            "paceBands": [{"name": "Tempo", "range": "5:40-6:10"}],
            "weeks": [{"sessions": [
                {"type": "tempo", "dist": "7 km", "workout": {"name": "5x3min", "steps": [
                    {"type": "warmup", "time": 600},
                    {"repeat": 5, "steps": [{"type": "interval", "time": 180, "pace": "Tempo"},
                                            {"type": "recovery", "time": 120, "hr": "120-135", "zone": 1}]},
                    {"type": "cooldown", "distance": 1500}]}},
                {"type": "easy", "dist": "5 km", "workout": {"name": "Easy", "steps": [{"type": "run", "distance": 5000}]}},
            ]}],
        }
        path = os.path.join(tempfile.mkdtemp(), "plan.json")
        with open(path, "w") as f:
            json.dump(plan, f)
        targets = week_targets(1, "de", path)
        self.assertEqual(len(targets), 1)   # easy runs only with uploadEasyRuns
        self.assertEqual(targets[0]["name"], "PL W01 · 5x3min")
        text = "\n".join(targets[0]["phases"])
        self.assertIn("5× wiederholen", text)
        self.assertIn("Pace 5:40–6:10/km", text)
        self.assertIn("HF-Zone 1 (120–135 bpm)", text)
        self.assertIn("1,50 km", text)
        self.assertIsNone(week_targets(9, "de", path))


class FakePolar(BaseHTTPRequestHandler):
    """Polar's token endpoint and user registration (already registered → 409)."""
    requests = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        FakePolar.requests.append((self.path, self.headers.get("Authorization"), body))
        if self.path == "/token":
            form = urllib.parse.parse_qs(body)
            ok = form.get("code") == ["the-code"] and form.get("grant_type") == ["authorization_code"]
            self.send_response(200 if ok else 400)
            self.end_headers()
            self.wfile.write(json.dumps({"access_token": "tok", "token_type": "bearer", "x_user_id": 42,
                                         "expires_in": 31535999}).encode())
        elif self.path == "/v3/users":
            self.send_response(409)
            self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"first-name": "Ada", "last-name": "L"}).encode())

    def log_message(self, *args):
        pass


class Login(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", FAKE_PORT), FakePolar)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_flow(self):
        flow = api.LoginFlow("client", "secret", "ok")
        flow.start()
        query = urllib.parse.parse_qs(urllib.parse.urlparse(flow.url).query)
        self.assertEqual(query["redirect_uri"], [api.REDIRECT_URI])
        # The browser comes back with the code.
        callback = f"http://127.0.0.1:{api.REDIRECT_PORT}{api.REDIRECT_PATH}?code=the-code&state={flow.state}"
        threading.Thread(target=lambda: urllib.request.urlopen(callback, timeout=5).read()).start()
        account = flow.wait(10)
        self.assertEqual(account["access_token"], "tok")
        self.assertEqual(account["user_id"], 42)
        token_call = next(r for r in FakePolar.requests if r[0] == "/token")
        self.assertTrue(token_call[1].startswith("Basic "))
        self.assertIn("redirect_uri=", token_call[2])
        register = next(r for r in FakePolar.requests if r[0] == "/v3/users")
        self.assertEqual(json.loads(register[2]), {"member-id": "pacelab-42"})
        api.save_account(account)
        self.assertEqual(oct(os.stat(api.TOKEN_FILE).st_mode & 0o777), "0o600")
        self.assertEqual(api.load_account()["user_id"], 42)

    def test_wrong_state_is_rejected(self):
        flow = api.LoginFlow("client", "secret", "ok")
        flow.start()
        callback = f"http://127.0.0.1:{api.REDIRECT_PORT}{api.REDIRECT_PATH}?code=x&state=forged"
        threading.Thread(target=lambda: urllib.request.urlopen(callback, timeout=5).read()).start()
        with self.assertRaises(api.PolarError):
            flow.wait(10)


if __name__ == "__main__":
    unittest.main()
