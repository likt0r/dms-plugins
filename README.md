# dms-plugins

Eigene Plugins/Widgets für [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
(DMS) unter niri auf Fedora. Nachfolger der `likt0r/omarchy-*`-Plugins; der
Umstiegsplan mit der Portierungs-Tabelle liegt im dotfiles-Repo
(`docs/umstieg-niri-dms-fedora.md`).

Ein Plugin pro Verzeichnis, jeweils mit `plugin.json` (Manifest) und den
QML-Komponenten. Entwickelt wird mit dem offiziellen Skill `dms-plugin-dev`
aus dem DMS-Repo.

## Installation

`bin/apply` aus dem dotfiles-Repo verlinkt jedes Verzeichnis nach
`~/.config/DankMaterialShell/plugins/`. Von Hand:

```sh
ln -s ~/projects/private/dms-plugins/<name> ~/.config/DankMaterialShell/plugins/<name>
dms ipc call plugins reload <id>   # oder DMS neu starten
```

Aktivieren: DMS-Einstellungen → Plugins, dann das Widget in der Bar-Belegung
platzieren.

## Plugins

| Plugin | Typ | Zweck |
|---|---|---|
| [`schalter/`](schalter/) | widget | **Umschalter-Gruppe** in der Bar-Mitte: Wachhalten, VPN, Diktat, Bildschirmaufnahme (Auswahl als HUD auf F10) und Benachrichtigungen. Aktive Icons stehen immer da, die uebrigen erscheinen beim Hovern. Ersatz fuer Omarchys `omarchy.indicators`. |
| [`aufnahmeKachel/`](aufnahmeKachel/) | widget (Control Center) | Kachel fuer die Bildschirmaufnahme der schalter-Gruppe: Laufzeit, Klick = Auswahl/Stopp. |
| [`diktatKachel/`](diktatKachel/) | widget (Control Center) | Kachel fuers Diktat (voxtype) der schalter-Gruppe. |
| [`bildschirme/`](bildschirme/) | widget | Bildschirmmodus umschalten wie GNOMEs Super+P: alle, nur extern, nur intern, spiegeln (ueber wl-mirror) -- dazu die DMS-Anzeigeprofile. Gedacht fuer die Anzeige-Sondertaste F7. |
| [`flugmodus/`](flugmodus/) | widget | Flugzeug-Icon in der Bar, solange der Flugmodus laeuft -- sonst nichts; OSD beim Umschalten. Klick schaltet ihn aus. |
| [`vpn/`](vpn/) | widget | **VPN Hub** (Id `vpnHub`): ein Icon für alle VPNs — NetworkManager-Profile und Proton VPN über die offizielle CLI; Popout mit Status, Traffic, Schaltern, Länderauswahl und Favoriten. Port von `likt0r.vpn`. |
| [`voxtype/`](voxtype/) | widget | Diktat-Status in der Bar (voxtype) und als OSD: laufende Wellenform waehrend der Aufnahme, Spinner beim Transkribieren. Klick: Aufnahme an/aus, Rechtsklick: Konfiguration. Ersatz für Omarchys `Dictation.qml` und fuer voxtypes GTK4-Overlay. |

## Geplant (Portierung von Omarchy, siehe Umstiegsplan Phase 3)

Offen: `wake`. Portiert: `warthemahl` (Pilot), `scribe`, `calendar`, `vpn`.

## Themes

Unter `themes/` liegen DMS-Farbthemes (ein Verzeichnis pro Theme mit
`theme.json` + Preview-SVGs). `bin/apply` verlinkt sie nach
`~/.config/DankMaterialShell/themes/`; aktiviert wird über die
DMS-Einstellungen (Theme → Colors) oder per settings.json
(`currentThemeName: "custom"`, `customThemeFile: <pfad>/theme.json`).

| Theme | Beschreibung |
|---|---|
| [`themes/faktenforum/`](themes/faktenforum/) | Faktenforum-Branding (Indigo/Zinc aus dem Nuxt-UI-Frontend, Korall als Zweitakzent), dark + light. Dazu gehören die Fonts Source Sans 3 / Source Code Pro (`fontFamily`/`monoFontFamily`, Installation über das dotfiles-Repo) und ein Wallpaper (`wallpaper.jpg`, Quelle `wallpaper.svg`; setzen mit `dms ipc call wallpaper set ~/.config/DankMaterialShell/themes/faktenforum/wallpaper.jpg`). |
