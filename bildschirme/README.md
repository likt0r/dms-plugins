# Bildschirme

Bildschirmmodus umschalten wie GNOMEs Super+P: ein Popout mit allen Modi,
der aktive markiert. Gedacht fuer die Anzeige-Sondertaste des ThinkPads
(F7, Keysym `XF86Display`).

![Modi: alle, nur extern, nur intern, spiegeln -- dazu die DMS-Anzeigeprofile]

## Bedienung

| Weg | Wirkung |
|---|---|
| F7 (`dms ipc call bildschirme taste`) | Auswahl unten am Bildschirm; weitere Drucke wandern, nach 1,2 s wird uebernommen |
| Klick aufs Bar-Icon | Popout mit Modi und Anzeigeprofilen |
| Rechtsklick aufs Bar-Icon | eine Stufe weiter, ohne Anzeige |
| Esc / Klick daneben | Popout schliessen |

**F7 zeigt kein Popout mehr**, sondern ein HUD wie Lautstaerke und Flugmodus:
alle Modi nebeneinander, der gewaehlte gerahmt, nicht moegliche blass. Das ist
GNOMEs Super+P nachempfunden. Das Popout mit den Anzeigeprofilen bleibt am
Bar-Icon -- und das Bar-Icon erscheint nur bei angeschlossenem zweitem Schirm.

Zusaetzlich geht im HUD die Tastatur: **←/→** (auch ↑/↓, Tab) waehlen und
halten den Timer an, **Enter** uebernimmt, **Esc** bricht ohne Umschalten ab.
Dafuer bekommt das HUD, solange gewaehlt wird, den Tastaturfokus
(`WlrLayershell.keyboardFocus` ueber DMS' `KeyboardFocus.keyboardFocus`, nur auf
dem Schirm mit Fokus); ohne Taste verschwindet es nach 8 s. Im Popout gibt es
keine Pfeiltasten -- DMS-Popouts haben keinen KeyCatcher.

Zum Pruefen ohne zweiten Schirm: `dms ipc call bildschirme osd auswahl` zeigt
die Auswahlzeile, ohne dass etwas zu waehlen waere (endet nach 8 s von
selbst).

## Die Pille ist derzeit ganz abgeschaltet

Der Bar-Eintrag steht auf `{"id": "bildschirme", "enabled": false}` -- seit F7
die Auswahl als HUD zeigt, braucht es kein Icon mehr. Das Plugin laeuft
trotzdem weiter (`WidgetHost.active` haengt nicht an `enabled`), sonst waere
auch das HUD weg.

Preis: Das Popout mit den **Anzeigeprofilen** ist dann nur noch ueber
`dms ipc call bildschirme toggle` erreichbar, nicht mehr per Klick. Wer es
zurueck will, setzt den Eintrag auf `enabled: true` -- dann greift wieder die
Regel unten.

## Wann die Pille zu sehen ist, falls wieder eingeschaltet

Nur, wenn ein externer Schirm angeschlossen ist -- ohne zweiten Monitor gibt
es nichts umzuschalten. Die Pille haengt an `hatExtern`; beim An- und
Abstecken liest das Plugin sofort nach (`Quickshell.onScreensChanged`), ein
angeschlossener aber abgeschalteter Schirm faellt erst dem 30-Sekunden-Takt
auf. F7 oeffnet das Popout unabhaengig davon.

## Modi

- **Alle Bildschirme** — intern und extern an
- **Nur extern** — intern aus
- **Nur intern** — extern aus
- **Spiegeln** — beide an, `wl-mirror` legt den internen Schirm im Vollbild
  auf den externen

Darunter die **Anzeigeprofile** von DMS (Anordnung und Aufloesung, nicht
an/aus) — ein Klick aktiviert eins.

## Warum Spiegeln ueber wl-mirror laeuft

niri kann nicht spiegeln: weder `mirror`/`clone-of` in der Output-Config
noch eine Aktion dafuer. Geplant ist es auch nicht — niri-wm/niri
Discussion #1152, YaLTeR im Feb 2025: *"I agree it would be useful, but
display mirroring is somewhat complicated."* Der etablierte Ersatz im
niri-Umfeld ist [wl-mirror](https://github.com/Ferdi265/wl-mirror); das
Monitor-Tool [nirimon](https://github.com/stepbrobd/nirimon) macht es
genauso. Haken: bei unterschiedlichem Seitenverhaeltnis schwarze Balken,
und beendet wird durch Abschiessen des Prozesses.

Ohne installiertes `wl-mirror` steht der Modus ausgegraut mit Hinweis da.

## Abhaengigkeiten

Geschaltet wird nicht im QML, sondern in `~/.local/bin/monitor-modus` aus
dem dotfiles-Repo (`localbin/monitor-modus`, Python). Das Plugin liest von
dort `status` als JSON und ruft `alle|extern|intern|spiegeln` bzw.
`profil <name>` auf. Fehlt das Skript, blockt der StartupCheck das Plugin
mit einem Hinweis statt eine tote Liste zu zeigen.

Optional: `wl-mirror` (Fedora: `dnf install wl-mirror`).

## IPC

```
dms ipc call bildschirme taste            # F7: oeffnen, dann weiterschalten
dms ipc call bildschirme toggle           # nur das Popout
dms ipc call bildschirme waehle <modus>   # alle|extern|intern|spiegeln
dms ipc call bildschirme weiter
dms ipc call bildschirme status
```
