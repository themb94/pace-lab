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
  "avg_hr": 151, "max_hr": 178, "elevation_gain": 40, "cadence": 84,
  "weather": "…",                // optional
  "flags": ["…"],                // kurze Hinweise
  "splits": [ { "km": 1, "pace_s": 381, "hr": 138 }, { "label": "Intervall 1", "pace_s": 330, "hr": 165 } ],
  "verdict": "gut",              // "gut" | "ok" | "achtung"
  "analysis": "…",               // Auswertung als Fließtext
  "adjustments": "…"             // Folgerung für die nächste Woche oder null
}
```

Wochenfazits kommen nach `weekSummaries: [{ "week": 1, "analysis": "…", "nextWeekChanges": "…" }]`.

**Von der App geladene Läufe** (mit `source` und `verdict: null`) bei der
Auswertung **ergänzen statt neu anlegen**: IDs und Messwerte behalten, Split-Labels
bei Intervallen präzisieren, `sessionId`, `flags`, `verdict`, `analysis`,
`adjustments` setzen.

## Erledigte Einheiten (`completed.json`)

`{ "b1w1-tempo-0": "06.01.2026", … }` — Schlüssel ist die Session-ID, Wert das Datum
(`TT.MM.JJJJ`). Reihenfolge der vorhandenen Einträge beibehalten.

## Wochenauswertung

1. **Läufe holen** — Strava über den Strava-MCP (`list_activities`,
   `get_activity_performance`), falls eingerichtet, sonst über die Uhr — Garmin oder
   Polar (`list_activities`, `get_activity_data`). Oft hat die App sie schon geladen.
2. **Struktur rekonstruieren:** Bei Intervall-Workouts ergeben aufeinanderfolgende
   Runden zusammen die geplanten Abschnitte.
3. `completed.json` und `analysis.json` aktualisieren, Wochenfazit in `weekSummaries`.
4. Kurze Zusammenfassung: Läufe, Bewertung, Empfehlung für die nächste Woche.
5. Erst danach die nächste Woche vorbereiten (`plan.json`). Garmin-Workouts nur mit
   ausdrücklicher Freigabe anlegen (bei Polar zeigt die App die Woche zum Eintragen).

## Garmin

Der Garmin-Server (MCP) wird von Pace Lab eingerichtet und ist in `.mcp.json`
eingetragen. Werkzeuge: `garmin_status`, `list_activities`, `get_activity_data`,
`list_workouts`, `preview_plan(week)`, `create_plan(week, dry_run, replace_existing)`,
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
