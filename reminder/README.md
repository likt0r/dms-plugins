# Timer

Timer mit optionaler Notiz für DankMaterialShell: Zeit eingeben, optional
eine Notiz, und wenn die Zeit um ist, kommt eine Benachrichtigung, die stehen
bleibt, dazu ein Ton. Nachbau der Reminders aus Omarchy
(`bin/omarchy-reminder`, `shell/plugins/reminders/ReminderFlow.qml` und der
Bar-Indikator `Reminder.qml` aus
[basecamp/omarchy](https://github.com/basecamp/omarchy), MIT).

## Wo es sitzt

- **Toggle-Leiste** (Plugin [`schalter`](../schalter/)): Die Stoppuhr steht
  dort, solange ein Timer läuft, sonst erscheint sie wie die anderen
  Schalter beim Hovern. Auf Wunsch steht die Restzeit des nächsten Timers
  daneben (Einstellung, Standard aus).
- **Klick auf die Stoppuhr:** Popout mit den laufenden Timern (Notiz oder
  „Timer“, Uhrzeit, Restzeit, löschen; im Kopf „Alle löschen“) und dem Knopf
  **„Timer hinzufügen“**.
- **`Mod+Alt+T`** (niri-Keybind im dotfiles-Repo) oder der Knopf öffnen das
  **HUD** unten am Bildschirm, auf dem Schirm mit Fokus.

Die eigene Pille des Plugins ist in der Bar ausgeschaltet
(`{"id": "reminder", "enabled": false}` in `centerWidgets`). Das Plugin läuft
trotzdem, denn Popout, HUD und IPC wohnen hier. Gefunden wird es wie
`vpnHub`: Die Instanz liegt je Schirm in `PluginService.globalVars` unter
`reminder` / `anker:<Schirm>`. `schalter` liest dort den Zustand (`leiste`) und
ruft `popoutAnkern()`, damit das Popout unter der Stoppuhr aufgeht.

## Das HUD

Zwei Schritte nacheinander, wie Omarchys Overlay:

1. **Zeit.** Ein Textfeld, darunter die Vorgaben als Kacheln.
   - **←/→** (auch ↑/↓, Tab) wählen eine Vorgabe und schreiben sie ins Feld.
     Tippen überschreibt.
   - In der Kopfzeile steht sofort „Timer 25 min · um 14:45“ oder was am
     Format nicht stimmt.
   - **Enter** übernimmt, ein Klick auf eine Kachel ebenso.
2. **Notiz (optional).** Das Feld erscheint erst jetzt. **Enter** stellt den
   Timer, auch mit leerem Feld, dann ist es ein Timer ohne Namen.
   **Backspace** im leeren Feld geht zurück zur Zeit.

**Esc** bricht in jedem Schritt ab.

Die Zeit versteht:

| Eingabe | bedeutet |
|---|---|
| `25` | 25 in der eingestellten Einheit (Standard Minuten, sonst Stunden oder Sekunden) |
| `3h30m4s`, `3h 30m 4s` | 3 h 30 min 4 s, Einheiten absteigend, jede einmal |
| `90m`, `90min`, `45s`, `2h` | einzeln |
| `1h30`, `5m30` | eine Zahl am Ende zählt in der nächstkleineren Einheit |
| `14:30`, `14.30` | bis 14:30, heute oder, wenn schon vorbei, morgen |

## Einstellungen

Einstellungen → Plugins → Timer:

| Einstellung | Schlüssel | Standard |
|---|---|---|
| Zahl ohne Einheit | `bareUnit` (`m`/`h`/`s`) | Minuten |
| Vorgaben | `presets` | `5m, 10m, 15m, 25m, 45m, 1h` (durch Komma getrennt) |
| Restzeit in der Toggle-Leiste | `showCountdown` | aus (nur Icon) |
| Ton beim Ablauf | `playSound` | an, gilt für neu gestellte Timer |

## Von außen

```sh
dms ipc call reminder openHud
dms ipc call reminder openPopout
dms ipc call reminder add 25 "Tee"      # ohne HUD; "" = ohne Notiz
dms ipc call reminder list
dms ipc call reminder clear

bin/dms-reminder 3h30m4s "Wäsche"       # ohne Shell
bin/dms-reminder --unit s 90
bin/dms-reminder show
```

## Wie es funktioniert

Wie bei Omarchy ist jeder Timer ein transienter systemd-User-Timer
(`systemd-run --user --on-active=…`, Unit `dms-reminder-<zeit>-<pid>`):
- Die Notiz liegt in `$XDG_RUNTIME_DIR/dms-reminders/<unit>.message`.
- Die Fälligkeit liest `dms-reminder show --json` aus
  `systemctl --user list-timers`.
- Timer überleben einen Neustart der Shell, nicht aber einen des Rechners.

Beim Ablauf läuft im Timer:
- `notify-send -u critical --transient`: Das Popup bleibt stehen, bis man es
  wegklickt, und kommt auch bei „Nicht stören“. Danach ist es ganz weg, denn
  transiente Meldungen legt DMS weder ins Benachrichtigungszentrum noch in den
  Verlauf, und die Glocke leuchtet nicht nach. `suppress-sound` verhindert
  einen zweiten Ton von DMS. Der Titel ist die Notiz, ohne Notiz „Timer
  abgelaufen“, im Text steht die Dauer.
- Der Systemton `alarm-clock-elapsed` (`canberra-gtk-play`, sonst `pw-play`).
- Danach wird die Notizdatei gelöscht und das Widget per
  `dms ipc call reminder refresh` angestoßen.

Das Widget zählt im Sekundentakt, solange etwas läuft oder das HUD offen ist.
Die Liste liest es neu beim Start, nach jeder Aktion, beim Öffnen des Popouts,
auf `refresh` und zur Sicherheit jede Minute.

Beim Stellen gibt es keine Benachrichtigung, das Timer-Icon in der
Toggle-Leiste zeigt ja, dass einer läuft. Nur wenn das Stellen scheitert,
kommt eine Benachrichtigung. Die Details stehen im Journal
(`journalctl --user -u dms -g '\[reminder\]'`).

Das HUD ist gebaut wie das Aufnahme-HUD in `schalter`: ein `DankOSD` je
Bildschirm. Den Tastaturfokus hat es nur, solange es offen ist, und nur auf
dem Schirm mit Fokus (`NiriService.currentOutput`). Die Steuertasten fängt ein
kleines Item ab, an das `DankTextField` über `keyForwardTargets` zuerst
weiterreicht. Alles andere geht als Text ins Feld.

Abweichungen von Omarchy:
- Ein HUD unten statt eines Vollbild-Overlays.
- Ein flexibles Zeitformat mit einstellbarer Einheit statt nur Minuten.
- Vorgaben mit Pfeiltasten.
- Ein Icon in der Toggle-Leiste und die Liste mit einzeln löschbaren Timern.
- Ton beim Ablauf.
- Keine Bestätigung beim Stellen.
- Keybind `Mod+Alt+T` statt `Super+Ctrl+R`, das unter niri belegt ist.

## Aufbau

```
plugin.json          Manifest (Id reminder)
ReminderWidget.qml   Anker für schalter, Popout, HUD, IPC (+ eigene Pille, normal aus)
Settings.qml         Einheit, Vorgaben, Restzeit, Ton
Model.js             alles Reine: Zeitformat, Vorgaben, Countdown, Liste, Leisten-Zustand
bin/dms-reminder     Timer stellen/listen/löschen (Bash, Port von omarchy-reminder)
tests/               node --test (prüft auch, dass das Skript dieselben Formate versteht)
```

## Tests

```sh
node --test tests/model.test.js
```

## Lizenz

MIT, siehe [LICENSE](LICENSE).
