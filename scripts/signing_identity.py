"""
Sucht im Schlüsselbund das passende „Developer ID Application“-Zertifikat für eine Team-ID.
Gibt eine Zeile aus (Tab-getrennt): SHA-1, Ablauf (Unix-Zeit), alte Zertifizierungsstelle (1/0), Name.
Gibt es mehrere gültige, gewinnt das mit dem spätesten Ablauf. Nichts gefunden → keine Ausgabe.

Aufruf:  python3 signing_identity.py <Team-ID>
"""
import base64
import calendar
import hashlib
import re
import subprocess
import sys
import time


def run(*command, data=None):
    return subprocess.run(command, input=data, capture_output=True, text=True).stdout


team = sys.argv[1]
# Nur gültige Identitäten (mit privatem Schlüssel, nicht abgelaufen).
identities = dict(re.findall(
    r'^\s*\d+\) ([0-9A-F]{40}) "(Developer ID Application: .*\(%s\))"' % re.escape(team),
    run("security", "find-identity", "-v", "-p", "codesigning"), re.M))

best = None
certificates = run("security", "find-certificate", "-a", "-c", "Developer ID Application", "-p")
for pem in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", certificates, re.S):
    der = base64.b64decode("".join(pem.splitlines()[1:-1]))
    sha1 = hashlib.sha1(der).hexdigest().upper()
    if sha1 not in identities:
        continue
    info = run("openssl", "x509", "-noout", "-enddate", "-issuer", data=pem)
    end = calendar.timegm(time.strptime(re.search(r"notAfter=(.*)", info).group(1).strip(), "%b %d %H:%M:%S %Y %Z"))
    # Die alte Developer-ID-Zertifizierungsstelle (OU „Apple Certification Authority“, nicht „G2“) läuft am 1.2.2027 ab.
    old_authority = bool(re.search(r"OU\s*=\s*Apple Certification Authority", info))
    if best is None or end > best[1]:
        best = (sha1, end, old_authority, identities[sha1])

if best:
    print("\t".join([best[0], str(best[1]), "1" if best[2] else "0", best[3]]))
