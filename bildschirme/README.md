# Bildschirme

Bildschirmmodus umschalten wie GNOMEs Super+P: ein Popout mit allen Modi,
der aktive markiert. Gedacht fuer die Anzeige-Sondertaste des ThinkPads
(F7, Keysym `XF86Display`).

![Modi: alle, nur extern, nur intern, spiegeln -- dazu die DMS-Anzeigeprofile]

## Bedienung

| Weg | Wirkung |
|---|---|
| F7 (`dms ipc call bildschirme taste`) | Popout oeffnen; bei offenem Popout eine Stufe weiter |
| Klick aufs Bar-Icon | Popout oeffnen |
| Rechtsklick aufs Bar-Icon | eine Stufe weiter, ohne Popout |
| Esc / Klick daneben | schliessen |

Pfeiltasten gibt es nicht — DMS-Popouts haben keinen KeyCatcher.

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
