# Scribe

Text markieren. Taste drücken. Die korrigierte Fassung liegt in der
Zwischenablage.

Scribe ist ein DankMaterialShell-Plugin — der Port des Omarchy-Plugins
[likt0r.scribe](https://github.com/likt0r/omarchy-scribe) (Zuordnung
Omarchy→DMS: `docs/omarchy-to-dms.md` im dotfiles-Repo). Es liest die primäre
Auswahl, schickt sie mit einem Prompt an ein LLM, der Rechtschreibung,
Grammatik und Zeichensetzung korrigiert und Sprache, Ton und Formatierung
bewahrt, kopiert das Ergebnis zurück und meldet sich. Das Bar-Icon („Aa" über
einer Linie) zeigt den laufenden Abruf; Klick oder Keybind öffnen das
Prompt-Grid auf einem abgedunkelten Vollbild-Overlay, dahinter liegen History,
Prompt-Editor und alle Einstellungen.

## Installation

Das Repo wird von `bin/apply` (dotfiles) nach
`~/.config/DankMaterialShell/plugins/scribe` verlinkt. Danach:

```sh
dms ipc call plugins scan
dms ipc call plugins enable scribe
```

In der Bar platzieren (settings.json, `centerWidgets`/`rightWidgets`) und einen
Keybind in `~/.config/niri/config.kdl` setzen:

```kdl
Mod+Shift+G hotkey-overlay-title="Text korrigieren" { spawn "dms" "ipc" "call" "scribe" "correct"; }
```

Zum Schluss dem Standard-Backend den Anthropic-Schlüssel geben:

```bash
secret-tool store --label='Anthropic API key' service anthropic account api-key
```

Ein exportiertes `ANTHROPIC_API_KEY` geht auch und gewinnt. Wer gar keinen
API-Schlüssel will, stellt das Backend auf `claude-cli` um — es borgt sich,
womit die `claude`-CLI eingeloggt ist.

Prüfen, ob alles sitzt:

```bash
~/projects/private/dms-plugins/scribe/scribe doctor
```

## Bedienung

| | |
|---|---|
| **Keybind / Linksklick** | Prompt wählen, dann die Markierung korrigieren |
| **Pfeile / `hjkl`** | zwischen den Kacheln bewegen |
| **`1`–`9`** | Kachel direkt wählen |
| **Enter** | mit dem gewählten Prompt korrigieren |
| **letzte Kachel** | stattdessen eine Einmal-Anweisung tippen |
| **`s` / `p`** | Einstellungen / Prompts, ohne Maus |
| **Rechtsklick** | Overlay weg bzw. laufenden Abruf abbrechen |
| **Escape** | schließen ohne zu korrigieren |

Die Karte dahinter (Settings-Knopf oder `s`) hat drei Bereiche — History,
Prompts, Einstellungen — und ist durchgehend tastaturbedienbar (`←`/`→`
Bereich, `↑`/`↓` Prompt, Enter bearbeiten, `n`/`x`/`i` neu/löschen/Icon, `c`
korrigieren, `d` Setup-Check, Escape schließen).

Gegenüber dem Omarchy-Original weggefallen: der **Mittelklick** (sofort mit dem
Standard-Prompt korrigieren) — DMS-Pills kennen nur links und rechts. Der Weg
bleibt per IPC: `dms ipc call scribe correctNow`.

## Steuerung von außen

```bash
dms ipc call scribe correct          # Picker öffnen, dann korrigieren
dms ipc call scribe correctNow       # sofort mit dem Standard-Prompt
dms ipc call scribe correctWith <p>  # sofort mit Prompt <p>
dms ipc call scribe cancel           # Overlay weg / Abruf abbrechen
dms ipc call scribe status           # idle|working|done|error
dms ipc call scribe lastError        # warum der letzte Lauf scheiterte
```

## Dateien

```
plugin.json          Manifest (type widget, settings, Berechtigungen)
ScribeWidget.qml     Bar-Pill, Overlay (Grid/Composer/Karte), IPC
Settings.qml         Einstellungs-UI für die DMS-Settings-Seite
Model.js             Reine Logik: Zustandsmaschine, Profile, History, Keybind
scribe               CLI: Auswahl lesen, Backend rufen, wl-copy, History
backends/            anthropic · claude-cli · openai (deckt auch ollama ab)
icons.json           Nerd-Font-Glyphen für den Icon-Picker
tests/               run-tests.sh: CLI, Backends, Model.js, Manifest-Verdrahtung
```

Konfiguration: `~/.config/dms/scribe/` (profiles.json, eigene backends/),
History: `~/.local/state/dms/scribe/history.json`.

## Tests

```bash
cd ~/projects/private/dms-plugins/scribe
tests/run-tests.sh
```

Ohne Netz; der `claude-cli`- und der Live-Pfad haben eigene Tests
(`tests/live-test.py`), die nur auf Wunsch laufen.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
