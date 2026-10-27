# Trainingsordner (Pace Lab)

Dieser Ordner enthält deinen Trainingsplan und deine Lauf-Auswertungen. Die App
**Pace Lab** zeigt und ändert die Dateien, der **Coach** (Claude Code, Codex
oder ein lokales Modell) liest diese README vor jedem Gespräch. Alles, was hier
steht, gilt als Anweisung für den Coach — passe es an dich an.

## Athletenprofil

> Ausfüllen oder dem Coach im Chat erzählen („Trag in mein Athletenprofil ein …“).
> Engines ohne Dateizugriff (lokale Modelle) bekommen diesen Abschnitt mitgeschickt.

- **Name:**
- **Ziel:** (z. B. „10 km unter 55 Minuten“, „Halbmarathon im Frühjahr“, „fitter werden“)
- **Aktueller Umfang:** (Läufe pro Woche, km pro Woche, längster Lauf zuletzt)
- **Aktuelle Form / Bestzeiten:**
- **Maximalpuls:** (gemessen oder geschätzt — steht auch in `plan.json` → `athlete`)
- **Trainingstage / Zeitfenster:**
- **Gesundheit / Besonderheiten:** (optional — nur zur Einordnung der Daten, der
  Coach gibt keine medizinischen Ratschläge)
- **Vorlieben:** (z. B. „lockere Läufe ohne Pulsalarm“, „Intervalle lieber auf der Bahn“)

## Trainingsprinzipien

Standardregeln — ändere sie, wenn du es anders willst:

1. **Lockere Läufe nach Gefühl**, ohne Pace- oder Pulsziel auf der Uhr. Sie werden
   standardmäßig nicht als Workout für die Uhr angelegt (`"uploadEasyRuns": true` in
   `plan.json` ändert das).
2. **Long Runs** haben nur eine Distanz, kein Pace-Ziel.
3. **Pace-Ziele** nur für die harten Abschnitte einer Qualitätseinheit;
   Auf-/Auslaufen und Trabpausen sind frei. Lieber breite Bänder (20–40 s) als
   enge, damit die Uhr nicht ständig alarmiert.
4. **Höchstens zwei fordernde Einheiten pro Woche**, alle 3–4 Wochen eine
   Entlastungswoche.
5. **Woche für Woche:** erst die abgelaufene Woche auswerten, dann die nächste
   vorbereiten — nichts auf Vorrat auf die Uhr laden.
6. **Hohe Herzfrequenz** zuerst mit Hitze, Anstiegen, Tagesform (Schlaf, Stress)
   oder gesundheitlichen Faktoren erklären, bevor die Fitness infrage gestellt wird.
7. **Keine medizinischen Ratschläge** (Medikamente, Dosierungen) — dafür
   ist ärztlicher Rat zuständig.

## Dateien

```
plan.json            Aktiver Plan: Wochen, Einheiten, Workout-Schritte, Pace-Bänder, HF-Zonen
plan-entwurf.json    (zeitweise) Entwurf für den nächsten Block — wird in der App übernommen
plans/               Frühere Blöcke (beim Übernehmen eines Entwurfs abgelegt)
analysis.json        Alle Läufe mit Messwerten und Auswertung
completed.json       Welche Einheiten erledigt sind
.mcp.json            Anbindung des Uhr-Servers, Garmin oder Polar (legt die App an)
.git/                Verlauf — jede Änderung ist ein Stand und lässt sich zurücknehmen
```

## Plan-Schema (`plan.json`)

```jsonc
{
  "title": "Grundlagen-Block", "goal": "…", "subtitle": "…", "previous": "…",
  "startMonday": "2026-01-05",       // Montag der ersten Blockwoche
  "idPrefix": "b1",                  // Session-IDs: b1w1-tempo-0 … (je Block neu!)
  "workoutPrefix": "PL",             // Garmin-Namen: "PL W01 · 6x800m" (je Block neu)
  "uploadEasyRuns": false,           // lockere Läufe auch auf die Uhr?
  "athlete": { "maxHr": 190, "zoneFloors": [114, 133, 152, 171] },   // Untergrenzen Z2–Z5
  "paceBands": [{ "name": "Tempo", "range": "5:45–6:15", "note": "…" }],
  "weeks": [{
    "phase": "Aufbau", "note": "",
    "sessions": [{
      "type": "tempo",               // tempo | easy | long | race (Reihenfolge = Index in der ID)
      "dist": "~8 km", "desc": "6×800 m zügig · 90 s Trabpause",
      "workout": {
        "name": "6x800m",
        "steps": [
          { "type": "warmup", "time": 600, "note": "Locker einlaufen" },
          { "repeat": 6, "steps": [
            { "type": "interval", "distance": 800, "pace": "Intervalle", "note": "800 m zügig" },
            { "type": "recovery", "time": 90, "note": "90 s locker traben" } ] },
          { "type": "cooldown", "time": 600, "note": "Locker auslaufen" } ] } }] }]
}
```

- **Schritte:** `type` = `warmup` | `cooldown` | `interval` | `recovery` | `run`;
  Ende über `distance` (Meter) **oder** `time` (Sekunden); `repeat` + `steps` für
  Wiederholungen.
- **Ziele:** `"pace"` = Name eines `paceBands`-Eintrags (bevorzugt) oder
  `"m:ss-m:ss"`; `"hr": "lo-hi"` (+ optional `"zone"`). Ohne Ziel = nach Gefühl.
- **Session-IDs** (`{idPrefix}w{Woche}-{type}-{index}`) hängen an Typ und Position:
  Bei schon abgehakten Einheiten Typ und Reihenfolge nicht ändern.
- **Format:** 2 Leerzeichen Einrückung, kurze Objekte einzeilig (bis ~120 Zeichen).
- **Neuer Block:** als `plan-entwurf.json` mit **neuem** `idPrefix` und
  `workoutPrefix`; `plan.json` bleibt, bis der Entwurf in der App übernommen wird.

## Läufe (`analysis.json`)

Neueste zuerst. Schema pro Lauf:

```jsonc
{
  "source": "garmin",            // "garmin" | "polar" | "strava" — gesetzt, wenn die App den Lauf geladen hat
  "garminId": "…",               // bzw. "polarId" / "stravaId"
  "sessionId": "b1w1-tempo-0",   // oder null bei außerplanmäßigen Läufen
  "tag": "…",                    // nur wenn sessionId null ist, z. B. "Regeneration"
  "name": "…", "date": "2026-01-06",
  "distance_km": 7.4, "moving_time_s": 2710, "avg_pace_s": 366,
  "avg_hr": 151, "max_hr": 178, "elevation_gain": 40, "cadence": 84,   // cadence: Schritte eines Fußes
  "running_dynamics": {          // Garmin, nur wenn gemessen — siehe „Laufeffizienz“
    "cadence_spm": 168, "stride_length_cm": 107, "ground_contact_ms": 251,
    "gct_balance_left_pct": 49.8, "vertical_oscillation_cm": 9.1, "vertical_ratio_pct": 8.4 },
  "weather": "…",                // optional
  "flags": ["…"],                // kurze Hinweise
  "splits": [ { "km": 1, "pace_s": 381, "hr": 138, "cadence_spm": 166, "ground_contact_ms": 255, "stride_length_cm": 104 },
              { "label": "Intervall 1", "pace_s": 330, "hr": 165 } ],
  "verdict": "gut",              // "gut" | "ok" | "achtung"
  "analysis": "…",               // Auswertung als Fließtext
  "adjustments": "…",            // Folgerung für die nächste Woche oder null
  "running_form": "…"            // Laufstil: 2–3 Empfehlungen oder null
}
```

Wochenfazits kommen nach `weekSummaries: [{ "week": 1, "analysis": "…", "nextWeekChanges": "…" }]`.

**Von der App geladene Läufe** (mit `source` und `verdict: null`) bei der
Auswertung **ergänzen statt neu anlegen**: IDs und Messwerte behalten, Split-Labels
bei Intervallen präzisieren, `sessionId`, `flags`, `verdict`, `analysis`,
`adjustments` und — mit Laufeffizienz — `running_form` setzen.

## Laufeffizienz (Garmin)

Mit einer Uhr oder einem Sensor, der sie misst (z. B. HRM-Pro, Running Dynamics Pod),
liefert Garmin die Laufeffizienz (Laufdynamik). Die App speichert sie in
`running_dynamics` und pro Split; der Garmin-Server liefert sie in `get_activity_data`
(Zusammenfassung und Runden) und `list_activities`.

| Wert | Feld | Garmins Skala (grün = Durchschnitt, blau/lila besser) |
|---|---|---|
| Schrittfrequenz | `cadence_spm` (beide Füße) | grün 164–173, blau 174–183, lila > 183 |
| Bodenkontaktzeit | `ground_contact_ms` | grün 249–277, blau 218–248, lila < 218 |
| Balance der Bodenkontaktzeit | `gct_balance_left_pct` | grün 49,3–50,7 % |
| Vertikale Bewegung | `vertical_oscillation_cm` | grün 8,2–9,7, blau 6,4–8,1, lila < 6,4 |
| Vertikales Verhältnis | `vertical_ratio_pct` | grün 7,5–8,6, blau 6,1–7,4, lila < 6,1 |
| Schrittlänge | `stride_length_cm` | keine Skala (hängt von Größe und Tempo ab) |

So einordnen:

- Garmins Skala vergleicht mit allen Läufern. Entscheidend ist der Vergleich mit
  **eigenen Läufen bei ähnlichem Tempo und Typ** — lockere Läufe haben von Natur aus
  eine niedrigere Schrittfrequenz und längere Bodenkontakte.
- **Verlauf im Lauf:** Werden die Bodenkontakte gegen Ende länger oder die Schritte
  kürzer (bei gleichem Tempo), lässt die Form mit der Ermüdung nach.
- **Balance** über mehrere Läufe deutlich einseitig (über etwa 51,5 %): einseitige
  Schwäche oder Belastung — Schmerzen gehören in ärztliche oder physiotherapeutische Hände.

Empfehlungen kommen nach `running_form` des Laufs: 2–3 konkrete, machbare Punkte, z. B.

- **Schrittfrequenz** in kleinen Schritten erhöhen (etwa 5 %), Metronom oder Musik im Takt
- **Steigerungsläufe** (4–6 × 20 s locker schnell) nach lockeren Läufen
- **Lauf-ABC** (Skippings, Anfersen, Fußgelenksarbeit), Seilspringen, leichte
  Sprungübungen für reaktive Bodenkontakte
- **Kraft** für Rumpf, Hüfte und Waden; einbeinige Übungen bei Ungleichgewicht
- **Haltung:** aufrecht, leichte Vorlage aus den Sprunggelenken, unter dem Körper aufsetzen

Immer nur eine Sache auf einmal ändern und in den nächsten Läufen prüfen. Lauf-ABC- oder
Kraft-Einheiten für den Plan nur vorschlagen; eintragen erst auf Wunsch.

## Erledigte Einheiten (`completed.json`)

`{ "b1w1-tempo-0": "06.01.2026", … }` — Schlüssel ist die Session-ID, Wert das Datum
(`TT.MM.JJJJ`). Reihenfolge der vorhandenen Einträge beibehalten.

Fällt eine Einheit weg, kommt sie **nicht** in `completed.json`; stattdessen beginnt ihre
`desc` in `plan.json` mit „entfällt“ (z. B. „entfällt diese Woche – nicht nachholen“). Die
App zeigt sie dann als entfallen und nimmt sie nicht mehr als nächste Einheit.

## Wochenauswertung

1. **Läufe holen** — Strava über den Strava-MCP (`list_activities`,
   `get_activity_performance`), falls eingerichtet, sonst über die Uhr — Garmin oder
   Polar (`list_activities`, `get_activity_data`). Oft hat die App sie schon geladen.
2. **Struktur rekonstruieren:** Bei Intervall-Workouts ergeben aufeinanderfolgende
   Runden zusammen die geplanten Abschnitte.
3. `completed.json` und `analysis.json` aktualisieren, Wochenfazit in `weekSummaries`.
   Läufe mit Laufeffizienz bekommen einen Blick auf den Laufstil (`running_form`).
4. Kurze Zusammenfassung: Läufe, Bewertung, Empfehlung für die nächste Woche.
5. Erst danach die nächste Woche vorbereiten (`plan.json`). Garmin-Workouts nur mit
   ausdrücklicher Freigabe anlegen (bei Polar zeigt die App die Woche zum Eintragen).

## Garmin

Der Garmin-Server (MCP) wird von Pace Lab eingerichtet und ist in `.mcp.json`
eingetragen. Werkzeuge: `garmin_status`, `list_activities`, `get_activity_data`
(mit Laufeffizienz), `list_workouts`, `preview_plan(week)`, `create_plan(week, dry_run, replace_existing)`,
`delete_workout(id)`, `schedule_workout(id, date)`. Die Workouts entstehen aus
`plan.json`; `replace_existing=true` ersetzt gleichnamige Workouts statt sie zu
verdoppeln. Anlegen, Einplanen und Löschen nur mit Freigabe.

## Polar

Mit einer Polar-Uhr liest der Server `polar` (MCP) die Läufe über Polars offizielle
Schnittstelle (AccessLink): `polar_status`, `list_activities`, `get_activity_data`
(Runden sind Kilometer-Splits, berechnet aus den Messwerten der Uhr),
`preview_plan(week)`. Polar lässt keine anderen Apps Trainingsziele auf die Uhr
schreiben — die App zeigt eine Woche als Phasen zum Eintragen in Polar Flow
(Trainingsziel → Phasen). Polar liefert nur Trainings der letzten 30 Tage.

## Versionsverwaltung

Der Ordner ist ein git-Repository. Pace Lab hält jede Änderung als Stand fest
(Coach-Läufe, Häkchen, geladene Läufe) und kann sie zurücknehmen. **Als Coach
keine git-Befehle ausführen** — Lesen (`git log`, `git diff`) ist in Ordnung.
