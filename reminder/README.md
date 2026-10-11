# Erinnerung

Erinnerungen mit Countdown für DankMaterialShell: Zeit und Grund eingeben, und
wenn die Zeit um ist, kommt eine Benachrichtigung, die stehen bleibt, dazu ein
Ton. Nachbau der Reminders aus Omarchy (`bin/omarchy-reminder`,
`shell/plugins/reminders/ReminderFlow.qml` und der Bar-Indikator
`Reminder.qml` aus [basecamp/omarchy](https://github.com/basecamp/omarchy), MIT).

## Installation

`bin/apply` (dotfiles) verlinkt das Verzeichnis nach
`~/.config/DankMaterialShell/plugins/reminder`. Danach:

```sh
dms ipc call plugins scan
dms ipc call plugins enable reminder
```

und in der Bar-Mitte platzieren (`centerWidgets`, neben `calendar`).

## Bedienung

| Aktion | Wirkung |
|---|---|
| Klick auf den Wecker | Popout: neue Erinnerung, laufende Erinnerungen |
| `Mod+Alt+R` | dasselbe Popout per Tastatur (niri-Keybind im dotfiles-Repo) |
| Enter im Feld „Wann?“ | weiter zu „Woran erinnern?“ |
| Enter im Feld „Woran erinnern?“ | Erinnerung stellen |
| Schnellwahl-Knopf | trägt die Minuten ins Zeitfeld ein |
| ✕ an einer Erinnerung / Kopf-Knopf | eine bzw. alle löschen |

Die Zeit versteht:

| Eingabe | bedeutet |
|---|---|
| `15` | 15 Minuten (wie bei Omarchy) |
| `90m`, `90min` | 90 Minuten |
| `45s` | 45 Sekunden |
| `2h`, `1h30`, `1h 30m` | Stunden und Minuten |
| `14:30`, `14.30` | um 14:30, heute oder, wenn schon vorbei, morgen |

Unter dem Feld steht sofort, wann erinnert wird („um 14:45 · in 15 min“), oder
was am Format nicht stimmt. Ohne Grund lautet die Meldung „Deine 15 min sind um“.

In der Bar steht, solange eine Erinnerung läuft, der Wecker in der
Akzentfarbe und daneben die Restzeit der nächsten (`12:34`, ab einer Stunde
`1:05:00`).

Von außen:

```sh
dms ipc call reminder openPopout
dms ipc call reminder add 15 "Tee ist fertig"
dms ipc call reminder list
dms ipc call reminder clear
```

Oder ohne Shell direkt mit dem Skript:

```sh
bin/dms-reminder 1h30 "Wäsche aufhängen"
bin/dms-reminder show
bin/dms-reminder clear
```

## Einstellungen

Einstellungen → Plugins → Erinnerung:

- **Countdown in der Bar** (`showCountdown`, an)
- **Ton bei Fälligkeit** (`playSound`, an): gilt für neu gestellte Erinnerungen
- **Schnellwahl** (`quickTimes`, „5, 10, 15, 30, 60“)

## Wie es funktioniert

Wie bei Omarchy ist jede Erinnerung ein transienter systemd-User-Timer
(`systemd-run --user --on-active=…`, Unit `dms-reminder-<zeit>-<pid>`). Die
Nachricht liegt in `$XDG_RUNTIME_DIR/dms-reminders/<unit>.message`, die
Fälligkeit liest `dms-reminder show --json` aus `systemctl --user list-timers`.
Erinnerungen überleben deshalb einen Neustart der Shell, nicht aber einen
Neustart des Rechners.

Beim Auslösen läuft im Timer:
`notify-send -u critical` (bleibt stehen, kommt auch bei „Nicht stören“), der
Systemton `alarm-clock-elapsed` (`canberra-gtk-play`, sonst `pw-play`), dann
wird die Nachrichtendatei gelöscht und das Widget per
`dms ipc call reminder refresh` angestoßen.

Das Widget zählt im Sekundentakt herunter, solange etwas läuft, und liest die
Liste beim Start, nach jeder Aktion, beim Öffnen des Popouts, auf `refresh` und
zur Sicherheit jede Minute neu.

Bestätigung und Fehler kommen wie in den anderen Plugins als
Desktop-Benachrichtigung (Absender „Erinnerung“), Fehler mit Detail zusätzlich
im Log (`[reminder] …`), nicht als DMS-Toast.

Abweichungen von Omarchy:
- Statt eines Vollbild-Overlays mit zwei Schritten (erst Minuten, dann
  Nachricht) hat das Popout beide Felder untereinander; Enter führt durch wie
  dort.
- Flexibles Zeitformat statt nur Minuten.
- Countdown in der Bar, einzelne Erinnerungen löschbar, Ton.
- Keybind `Mod+Alt+R` statt `Super+Ctrl+R` (unter niri belegt durch
  `reset-window-height`).

## Aufbau

```
plugin.json          Manifest
ReminderWidget.qml   Bar-Pill mit Countdown, Popout, IPC
Settings.qml         Countdown, Ton, Schnellwahl
Model.js             alles Reine: Zeitformat, Countdown, Liste, Skript-Argumente
bin/dms-reminder     Timer stellen/listen/löschen (Bash, Port von omarchy-reminder)
tests/               node --test (prüft auch, dass das Skript dieselben Formate versteht)
```

## Tests

```sh
node --test tests/model.test.js
```

## Lizenz

MIT, siehe [LICENSE](LICENSE).
