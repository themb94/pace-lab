"""
Polar MCP server for Pace Lab.

Reads runs from Polar Flow through Polar's official AccessLink API — read-only. Polar offers no
interface for putting training targets on the watch; preview_plan describes a week as phased
targets to enter in Polar Flow instead.

Sign-in: OAuth in the browser with the user's own AccessLink client (admin.polaraccesslink.com,
redirect URL see polar_api.REDIRECT_URI). Client and token are stored in POLAR_TOKENSTORE.

Tools:
  polar_status          – check the sign-in
  polar_login_start     – start the sign-in (client from POLAR_CLIENT_ID/SECRET or stored); returns the URL to open
  polar_login_finish    – wait for the browser and store the token
  list_activities       – recent runs (compact, same keys as the Garmin server)
  get_activity_data     – summary, kilometer laps and heart-rate zones of a run
  preview_plan          – a week of the plan as Polar phases (no network)

Messages meant for people are written in German when PACELAB_LANG=de (set by the Pace Lab app).
"""
import json
import os

from mcp.server.fastmcp import FastMCP

import polar_api as api
from polar_targets import week_targets

mcp = FastMCP("polar")

LANG = os.environ.get("PACELAB_LANG") or ("de" if os.environ.get("LANG", "").startswith("de") else "en")
_state = {"flow": None}


def _t(en, de):
    return de if LANG == "de" else en


def _account():
    account = api.load_account()
    if not account.get("access_token"):
        raise api.PolarError(_t("Not signed in to Polar.", "Nicht bei Polar angemeldet."))
    return account


def _failure(e):
    if isinstance(e, api.PolarError) and e.status == 401:
        return _t("❌ The Polar sign-in has expired — sign in again in Pace Lab (Setup → Watch).",
                  "❌ Die Polar-Anmeldung ist abgelaufen — in Pace Lab neu anmelden (Einrichtung → Uhr).")
    if isinstance(e, api.PolarError) and e.status == 403:
        return _t("❌ Polar refuses access: accept all mandatory consents at account.polar.com, then try again.",
                  "❌ Polar verweigert den Zugriff: unter account.polar.com alle Pflicht-Einwilligungen bestätigen, dann erneut versuchen.")
    return f"❌ {e}"


@mcp.tool()
def polar_status() -> str:
    """Checks whether a Polar sign-in exists and works."""
    try:
        account = _account()
        user = api.api_get(f"/v3/users/{account['user_id']}", account["access_token"]) or {}
        name = " ".join(x for x in (api.field(user, "first-name"), api.field(user, "last-name")) if x)
        return _t(f"✅ Signed in to Polar as {name or account['user_id']}.",
                  f"✅ Bei Polar angemeldet als {name or account['user_id']}.")
    except Exception as e:
        return _failure(e)


@mcp.tool()
def polar_login_start() -> str:
    """Starts the Polar sign-in: returns JSON with the URL to open in the browser. Uses POLAR_CLIENT_ID and
    POLAR_CLIENT_SECRET (environment) or the stored client. Then call polar_login_finish."""
    stored = api.load_account()
    client_id = os.environ.get("POLAR_CLIENT_ID") or stored.get("client_id")
    client_secret = os.environ.get("POLAR_CLIENT_SECRET") or stored.get("client_secret")
    if not client_id or not client_secret:
        return _t("❌ Client ID and secret of your AccessLink client are missing.",
                  "❌ Client-ID und Secret deines AccessLink-Clients fehlen.")
    if _state["flow"]:
        _state["flow"].stop()
    flow = api.LoginFlow(client_id, client_secret,
                         _t("✅ Pace Lab is now connected to Polar. You can close this tab.",
                            "✅ Pace Lab ist jetzt mit Polar verbunden. Du kannst diesen Tab schließen."))
    try:
        flow.start()
    except Exception as e:
        return f"❌ {e}"
    _state["flow"] = flow
    return json.dumps({"url": flow.url, "redirect": api.REDIRECT_URI})


@mcp.tool()
def polar_login_finish(timeout: int = 300) -> str:
    """Waits (up to `timeout` seconds) until access was approved in the browser, then stores the token."""
    flow = _state["flow"]
    if not flow:
        return _t("❌ No sign-in in progress — call polar_login_start first.",
                  "❌ Keine Anmeldung offen — zuerst polar_login_start aufrufen.")
    try:
        account = flow.wait(timeout)
    except api.PolarError as e:
        text = str(e)
        if text == "timeout":
            return _t("❌ No answer from the browser — sign-in cancelled.", "❌ Keine Antwort aus dem Browser — Anmeldung abgebrochen.")
        if text == "access_denied":
            return _t("❌ Access was not granted in Polar Flow.", "❌ Der Zugriff wurde in Polar Flow nicht erlaubt.")
        return _t(f"❌ Sign-in failed: {text}", f"❌ Anmeldung fehlgeschlagen: {text}")
    finally:
        _state["flow"] = None
    api.save_account(account)
    return polar_status()


@mcp.tool()
def list_activities(limit: int = 5, activity_type: str = "running") -> str:
    """Lists the latest Polar training sessions (newest first; Polar passes on the last 30 days).
    activity_type="" includes all sports."""
    try:
        account = _account()
        exercises = api.api_get("/v3/exercises", account["access_token"]) or []
        if activity_type:
            exercises = [e for e in exercises if api.is_running(e)]
        exercises.sort(key=lambda e: str(api.field(e, "start_time", "")), reverse=True)
        compact = [api.compact(e, LANG) for e in exercises[:max(1, min(limit, 50))]]
        return json.dumps(compact, ensure_ascii=False, indent=2)
    except Exception as e:
        return _failure(e)


@mcp.tool()
def get_activity_data(activity_id: str) -> str:
    """Returns what a run analysis needs: summary, kilometer laps (computed from the samples) and
    heart-rate zones. Without GPS track and without per-second series, to stay compact."""
    try:
        account = _account()
        token = account["access_token"]
        exercise = api.api_get(f"/v3/exercises/{activity_id}?samples=true&zones=true", token) or {}
        tcx = None
        if not api.samples_by_type(exercise).get(api.DISTANCE):
            try:
                tcx = api.api_get(f"/v3/exercises/{activity_id}/tcx", token, accept="application/vnd.garmin.tcx+xml")
            except api.PolarError:
                tcx = None
        return json.dumps(api.activity_data(exercise, LANG, tcx=tcx), ensure_ascii=False, indent=2)
    except Exception as e:
        return _failure(e)


@mcp.tool()
def preview_plan(week: int = 1) -> str:
    """Shows the workouts of a block week from plan.json as Polar phased training targets (no upload —
    Polar doesn't allow that; they are entered in Polar Flow: Training targets → Phased)."""
    try:
        targets = week_targets(week, LANG)
    except Exception as e:
        return f"❌ {type(e).__name__}: {e}"
    if targets is None:
        return _t(f"Week {week} isn't in the plan.", f"Woche {week} gibt es im Plan nicht.")
    if not targets:
        return _t(f"No workouts for week {week}.", f"Keine Workouts in Woche {week}.")
    out = []
    for target in targets:
        out.append(f"### {target['name']} ({target['dist']})")
        out.extend(target["phases"])
        out.append("")
    return "\n".join(out).strip()


if __name__ == "__main__":
    mcp.run()
