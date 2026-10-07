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
| [`voxtype/`](voxtype/) | widget | Diktat-Status in der Bar (voxtype); Klick: Aufnahme an/aus, Rechtsklick: Konfiguration. Ersatz für Omarchys `Dictation.qml`. |

## Geplant (Portierung von Omarchy, siehe Umstiegsplan Phase 3)

`warthemahl` (Pilot), `wake`, `vpn`, `calendar`, `scribe`.

## Themes

Unter `themes/` liegen DMS-Farbthemes (ein Verzeichnis pro Theme mit
`theme.json` + Preview-SVGs). `bin/apply` verlinkt sie nach
`~/.config/DankMaterialShell/themes/`; aktiviert wird über die
DMS-Einstellungen (Theme → Colors) oder per settings.json
(`currentThemeName: "custom"`, `customThemeFile: <pfad>/theme.json`).

| Theme | Beschreibung |
|---|---|
| [`themes/faktenforum/`](themes/faktenforum/) | Faktenforum-Branding (Indigo/Zinc aus dem Nuxt-UI-Frontend, Korall als Zweitakzent), dark + light. Dazu gehören die Fonts Source Sans 3 / Source Code Pro (`fontFamily`/`monoFontFamily`, Installation über das dotfiles-Repo) und ein Wallpaper (`wallpaper.jpg`, Quelle `wallpaper.svg`; setzen mit `dms ipc call wallpaper set ~/.config/DankMaterialShell/themes/faktenforum/wallpaper.jpg`). |
