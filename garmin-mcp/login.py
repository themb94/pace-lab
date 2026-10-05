"""
One-time sign-in to Garmin Connect. Stores an OAuth token locally so that the MCP
server can work without credentials afterwards. MFA is supported.

Usage:  python login.py
"""
import os
import getpass

import garminconnect

TOKENSTORE = os.path.expanduser(os.environ.get("GARMIN_TOKENSTORE", "~/.garminconnect"))
LANG = os.environ.get("PACELAB_LANG") or ("de" if os.environ.get("LANG", "").startswith("de") else "en")


def _t(en, de):
    """German if the system language is German, English otherwise."""
    return de if LANG == "de" else en


def main():
    # First check whether a valid token already exists
    try:
        g = garminconnect.Garmin()
        g.login(TOKENSTORE)
        print(_t(f"Already signed in as {g.get_full_name()} (token in {TOKENSTORE}).",
                 f"Bereits angemeldet als {g.get_full_name()} (Token in {TOKENSTORE})."))
        return
    except Exception:
        pass

    email = os.environ.get("GARMIN_EMAIL") or input(_t("Garmin email: ", "Garmin-E-Mail: ")).strip()
    pw = os.environ.get("GARMIN_PASSWORD") or getpass.getpass(_t("Password: ", "Passwort: "))

    g = garminconnect.Garmin(email=email, password=pw, is_cn=False, return_on_mfa=True)
    res1, res2 = g.login()
    if res1 == "needs_mfa":
        code = input(_t("MFA one-time code: ", "MFA-Einmalcode: ")).strip()
        g.resume_login(res2, code)

    g.client.dump(TOKENSTORE)
    print(_t(f"✅ Signed in as {g.get_full_name()}. Token saved in {TOKENSTORE}.",
             f"✅ Angemeldet als {g.get_full_name()}. Token gespeichert in {TOKENSTORE}."))


if __name__ == "__main__":
    main()
