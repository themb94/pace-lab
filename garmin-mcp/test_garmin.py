"""
Offline tests for the Garmin activity data: summary, laps and running dynamics against a fake client.

Run: python3 -m unittest test_garmin   (in this folder; needs no packages)
"""
import unittest

from garmin_activity import activity_data, compact_activity, running_dynamics


class FakeGarmin:
    def __init__(self, summary, laps=(), listed=()):
        self.summary = summary
        self.laps = list(laps)
        self.listed = list(listed)
        self.list_calls = []

    def get_activity(self, activity_id):
        return {"activityId": int(activity_id), "activityName": "Stadtpark - PL W01 · 6x800m",
                "activityTypeDTO": {"typeKey": "running"}, "summaryDTO": self.summary}

    def get_activity_splits(self, activity_id):
        return {"lapDTOs": self.laps}

    def get_activity_weather(self, activity_id):
        raise RuntimeError("no weather")

    def get_activities_by_date(self, start, end=None, activitytype=None, sortorder=None):
        self.list_calls.append((start, end))
        return self.listed


SUMMARY = {
    "startTimeLocal": "2026-10-07 07:30:00", "distance": 8040.0, "movingDuration": 2710.0,
    "averageHR": 151.0, "averageRunCadence": 168.0, "strideLength": 107.36,
    "groundContactTime": 251.4, "verticalOscillation": 9.12, "verticalRatio": 8.43,
}


class RunningDynamicsTest(unittest.TestCase):
    def test_summary_names(self):
        self.assertEqual(running_dynamics(SUMMARY), {
            "strideLength": 107.4, "groundContactTime": 251.4, "verticalOscillation": 9.1, "verticalRatio": 8.4})

    def test_list_names_and_meters(self):
        listed = {"avgStrideLength": 1.12, "avgGroundContactTime": 240.0, "avgGroundContactBalance": 49.6,
                  "avgVerticalOscillation": 0.085, "avgVerticalRatio": 7.6}
        self.assertEqual(running_dynamics(listed), {
            "strideLength": 112.0, "groundContactTime": 240.0, "groundContactBalance": 49.6,
            "verticalOscillation": 8.5, "verticalRatio": 7.6})

    def test_first_source_wins_and_zero_is_missing(self):
        self.assertEqual(running_dynamics({"groundContactTime": 0, "verticalRatio": None},
                                          {"avgGroundContactTime": 260.0, "avgVerticalRatio": 8.0}),
                         {"groundContactTime": 260.0, "verticalRatio": 8.0})
        self.assertEqual(running_dynamics({}, None), {})


class ActivityDataTest(unittest.TestCase):
    def test_summary_filled_from_list(self):
        listed = [{"activityId": 99}, {"activityId": 42, "avgGroundContactBalance": 50.8, "avgStrideLength": 999}]
        client = FakeGarmin(SUMMARY, listed=listed)
        data = activity_data(client, "42")
        self.assertEqual(client.list_calls, [("2026-10-07", "2026-10-07")])
        summary = data["summary"]
        self.assertEqual(summary["groundContactBalance"], 50.8)
        self.assertEqual(summary["strideLength"], 107.4)   # the activity's own value wins
        self.assertEqual(summary["averageRunCadence"], 168.0)
        self.assertIn("error", data["weather"])

    def test_no_list_lookup_when_complete(self):
        client = FakeGarmin({**SUMMARY, "avgGroundContactBalance": 49.9})
        self.assertEqual(activity_data(client, "42")["summary"]["groundContactBalance"], 49.9)
        self.assertEqual(client.list_calls, [])

    def test_list_failure_keeps_summary(self):
        class Failing(FakeGarmin):
            def get_activities_by_date(self, *args, **kwargs):
                raise RuntimeError("offline")
        data = activity_data(Failing(SUMMARY), "42")
        self.assertEqual(data["summary"]["groundContactTime"], 251.4)
        self.assertNotIn("groundContactBalance", data["summary"])

    def test_laps_with_dynamics(self):
        laps = [
            {"lapIndex": 1, "distance": 1000.0, "movingDuration": 330.0, "averageHR": 150.0,
             "averageRunCadence": 166.0, "strideLength": 108.0, "groundContactTime": 248.0},
            {"lapIndex": 2, "distance": 40.0, "movingDuration": 20.0},
            {"lapIndex": 3, "distance": 800.0, "movingDuration": 230.0},
        ]
        data = activity_data(FakeGarmin(SUMMARY, laps=laps), "42")
        self.assertEqual(len(data["laps"]), 2)
        first, last = data["laps"]
        self.assertEqual((first["strideLength"], first["groundContactTime"], first["averageRunCadence"]), (108.0, 248.0, 166.0))
        self.assertNotIn("groundContactTime", last)

    def test_compact_activity(self):
        entry = compact_activity({"activityId": 7, "activityType": {"typeKey": "running"},
                                  "averageRunningCadenceInStepsPerMinute": 170.0, "avgGroundContactTime": 245.0})
        self.assertEqual(entry["runningDynamics"], {"groundContactTime": 245.0})
        self.assertNotIn("runningDynamics", compact_activity({"activityId": 8}))


if __name__ == "__main__":
    unittest.main()
