"""
Einmalige Anmeldung bei Garmin Connect. Speichert ein OAuth-Token lokal,
damit der MCP-Server danach ohne Zugangsdaten arbeitet. MFA wird unterstützt.

Aufruf:  python login.py
"""
import os
import getpass

import garminconnect

TOKENSTORE = os.path.expanduser(os.environ.get("GARMIN_TOKENSTORE", "~/.garminconnect"))


def main():
    # Erst prüfen, ob schon ein gültiges Token existiert
    try:
        g = garminconnect.Garmin()
        g.login(TOKENSTORE)
        print(f"Bereits angemeldet als {g.get_full_name()} (Token in {TOKENSTORE}).")
        return
    except Exception:
        pass

    email = os.environ.get("GARMIN_EMAIL") or input("Garmin-E-Mail: ").strip()
    pw = os.environ.get("GARMIN_PASSWORD") or getpass.getpass("Passwort: ")

    g = garminconnect.Garmin(email=email, password=pw, is_cn=False, return_on_mfa=True)
    res1, res2 = g.login()
    if res1 == "needs_mfa":
        code = input("MFA-Einmalcode: ").strip()
        g.resume_login(res2, code)

    g.client.dump(TOKENSTORE)
    print(f"✅ Angemeldet als {g.get_full_name()}. Token gespeichert in {TOKENSTORE}.")


if __name__ == "__main__":
    main()
