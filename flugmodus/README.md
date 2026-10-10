# Flugmodus

Ein Flugzeug-Icon in der Bar, solange der Flugmodus laeuft -- sonst gar
nichts. Beim Umschalten erscheint unten am Bildschirm dasselbe OSD wie bei
Lautstaerke und Helligkeit.

## Bedienung

| Weg | Wirkung |
|---|---|
| F8 (`XF86WLAN`, ruft `~/.local/bin/flugmodus`) | umschalten |
| Klick aufs Bar-Icon | ausschalten (es ist ja nur sichtbar, wenn an) |
| `dms ipc call flugmodus toggle` | umschalten |
| `dms ipc call flugmodus status` | "an" / "aus" |
| `dms ipc call flugmodus osd` | nur das OSD zeigen, ohne den Funk anzufassen |

## Woher der Zustand kommt

Nicht gepollt: `DMSNetworkService.wifiEnabled` und
`BluetoothService.available` schieben ihre Aenderungen selbst. Flugmodus
heisst hier **Funk aus UND kein Bluetooth-Adapter mehr da** -- beim Sperren
des ThinkPad-Schalters verschwindet `hci0` aus dem System, deshalb
`available` statt `enabled`. Beides zusammen, damit ein blosses WLAN-Aus im
Control Center nicht als Flugmodus durchgeht.

Weil der Zustand die Quelle ist und nicht der Tastendruck, erscheint das OSD
auch, wenn der Funk ueber das Control Center umgelegt wird.

## Zwei Fallen, die hier schon drinstecken

- **`parentScreen` ist in Plugin-Widgets `null`.** Ein einzelnes `DankOSD`
  mit `modelData: root.parentScreen` bekommt dadurch keine Geometrie
  (500x500, Position undefiniert) und bleibt unsichtbar. Richtig ist der Weg
  aus `DMSShell.qml`: `Variants { model: SettingsData.getFilteredScreens("osd") }`.
- **`effectiveVisible` setzt nur die Opazitaet auf 0.** Die Pille bliebe als
  Luecke in der Bar stehen. Deshalb zusaetzlich die Pille selbst nullbreit
  machen, nicht nur `setVisibilityOverride`.

## Abhaengigkeit

Geschaltet wird in `~/.local/bin/flugmodus` aus dem dotfiles-Repo
(`localbin/flugmodus`). Fehlt das Skript, blockt der StartupCheck das Plugin
mit einem Hinweis. Warum dort nmcli statt rfkill fuer WLAN benutzt wird,
steht im Kopf des Skripts.
