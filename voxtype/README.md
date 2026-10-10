# Voxtype Diktat

Diktat-Status in der Bar und als OSD unten am Bildschirm, im selben Stil wie
die DMS-OSDs fuer Lautstaerke und Helligkeit.

| Phase | Anzeige |
|---|---|
| Aufnahme | laufende Wellenform aus echten Mikrofonpegeln, 3 s Fenster |
| Transkription | Spinner und „Transkribiere…" |
| danach | blendet aus |

Das Bar-Icon bleibt daneben bestehen und pulsiert waehrend der Aufnahme.

## Bedienung

| Weg | Wirkung |
|---|---|
| Daumentaste / F12 / `Mod+Ctrl+X` | Aufnahme umschalten (macht voxtype bzw. niri) |
| Klick aufs Bar-Icon | Aufnahme umschalten |
| Rechtsklick | `voxtype configure` im schwebenden Terminal |
| `dms ipc call voxtype toggle` | Aufnahme umschalten |
| `dms ipc call voxtype status` | `<echte Phase>/<angezeigte Phase>` |
| `dms ipc call voxtype osd recording\|transcribing\|aus` | OSD mit Demo-Daten, ohne Mikrofon |

## Das Bar-Icon steht auf "aus" -- das Plugin trotzdem nicht

Seit es die Umschalter-Gruppe (`schalter/`) gibt, zeigt die den Diktat-Zustand
in der Bar-Mitte. Das eigene Icon waere doppelt und ist deshalb im Bar-Eintrag
abgeschaltet: `{"id": "voxtype", "enabled": false}` (in den DMS-Einstellungen
das Augen-Symbol beim Widget).

**Das Plugin aus `rightWidgets` zu entfernen waere etwas anderes und falsch:**
ein Plugin laeuft nur, solange sein Widget in der Bar steht -- mit dem Eintrag
verschwaende auch das OSD. `enabled: false` nimmt dagegen nur das Delegate aus
der Sektion; `WidgetHost.active` haengt nicht daran, Prozesse, IpcHandler und
die OSD-Fenster laufen weiter.

## Woher die Daten kommen

Beides von voxtype selbst, nichts geschaetzt und nichts nebenher
mitgeschnitten:

- **Zustand**: `voxtype status --follow --extended --format json` als
  Zeilenstrom.
- **Pegel**: `voxtype-audio-bridge` liest den Audio-Socket des Daemons
  (`$XDG_RUNTIME_DIR/voxtype/audio.sock`) und liefert NDJSON mit `peak`,
  `rms` und `vad`. Gekapselt in `VoxtypePegel.qml`.

Das GTK4-Overlay von voxtype ist abgeschaltet (`[osd] enabled = false` in der
config.toml des dotfiles-Repos) — sonst staenden zwei Anzeigen uebereinander.
Beide duerfen gleichzeitig am Socket lesen, das ist geprueft; es sieht nur
albern aus. Der Socket selbst ueberlebt `enabled = false`, er haengt am
Daemon, nicht am Overlay.

## Fallen, die hier schon eingearbeitet sind

- **Abgeleitete Properties im `onPhaseChanged`-Handler sind noch alt.** QML
  garantiert keine Auswertungsreihenfolge zwischen einem Change-Handler und
  Geschwister-Bindings. Eine erste Fassung las dort `phaseAktiv` und landete
  deshalb beim Eintritt in die Aufnahme im falschen Zweig. Im Handler wird
  alles aus `root.phase` neu gerechnet.
- **`voxtype status` schiebt beim Phasenwechsel eine Zeile mit leerem
  `class`-Feld und „Unknown state" dazwischen.** Als `stopped` gedeutet
  liesse das Bar-Icon und OSD kurz auf den Leerlauf springen — solche Zeilen
  werden uebersprungen.
- **`parentScreen` ist in Plugin-Widgets `null`.** Ein einzelnes `DankOSD`
  damit bleibt ohne Geometrie unsichtbar; richtig ist
  `Variants { model: SettingsData.getFilteredScreens("osd") }`.
- **`DankOSD` zerstoert seinen Inhalt beim Verbergen**
  (`contentLoader.active: root.visible`). Ringpuffer und Phase liegen deshalb
  auf dem Plugin-Root, nicht im `content`.
- **`OSDManager.showOSD` verdraengt das zuvor sichtbare OSD** desselben
  Bildschirms. Eine Lautstaerkeaenderung waehrend der Aufnahme wuerde unseres
  wegschieben, und `resetHideTimer()` holt es nicht zurueck. Deshalb ein
  Herzschlag alle 500 ms gegen ein kurzes `autoHideInterval` von 1,5 s — das
  laesst fremden OSDs ihre Zeit und ist zugleich das Sicherheitsnetz gegen
  ein ewig stehendes Overlay.
- **Die Bridge liefert ~100 Frames/s** (gemessen 102 Hz, in Schueben von ~5
  alle 43 ms). Die fertige `AudioBridge.qml` von voxtype schreibt pro Frame
  vier QML-Properties und hat `running: true` fest verdrahtet; deshalb die
  eigene Fassung mit Akkumulation in einem nackten JS-Objekt und einem
  Prozess, der nur waehrend der Aufnahme laeuft.
- Nach `dms ipc call plugins reload voxtype` haengt das IPC-Target an der
  alten Instanz (quickshell#898) — dann `systemctl --user restart dms.service`.
