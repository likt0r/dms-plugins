# WartheMahl

Die Wochenspeisekarte von [warthemahl.de](https://warthemahl.de/speisekarte/) als
Bar-Widget für DankMaterialShell. Ein Klick auf das Besteck-Icon öffnet die
Gerichte der ganzen Woche, der heutige Tag ist hervorgehoben. Port des
Omarchy-Plugins [likt0r.warthemahl](https://github.com/likt0r/omarchy-warthemahl);
die Zuordnung Omarchy→DMS steht in `docs/omarchy-to-dms.md` im dotfiles-Repo.

## Installation

Dieses Repo wird von `bin/apply` (dotfiles) nach
`~/.config/DankMaterialShell/plugins/warthemahl` verlinkt. Danach:

```sh
dms ipc call plugins scan        # Plugin finden
```

Aktivieren unter Settings → Plugins, dann in der Bar-Konfiguration platzieren.

## Voraussetzungen

- DMS ≥ 1.6 (Paket `dms` aus dem COPR avengemedia/dms)
- `python3` (nur Standardbibliothek)
- `xdg-open` für PDF- und Website-Knöpfe
- Netzzugriff auf `warthemahl.de` — ohne Netz zeigt das Popout den letzten
  zwischengespeicherten Stand mit `OFFLINE`-Abzeichen

Cache: `${XDG_CACHE_HOME:-~/.cache}/dms/warthemahl-menu.json`

## Bedienung

| Aktion | Wirkung |
|---|---|
| Linksklick aufs Icon | Speisekarte öffnen / schließen |
| Rechtsklick | Neu laden (erzwingt einen Abruf, ignoriert den Cache) |
| Schalter im Popout | Nur vegetarische Gerichte zeigen |
| Knöpfe im Kopf | Neu laden · PDF der Woche · warthemahl.de |
| `Esc` | Schließen |

Gegenüber dem Omarchy-Original weggefallen: Tastatur-Navigation im Panel
(`↑`/`↓`/`r`/`p`/`v`/`w`), Mittelklick und der Bar-Tooltip — das DMS-Popout hat
keinen KeyCatcher und die Pills keine Tooltips. Als Ersatz für den Tooltip kann
die Einstellung „Heutiges Gericht in der Bar" das erste sichtbare Gericht neben
dem Icon einblenden (respektiert den Vegetarier-Filter).

## Einstellungen

Settings → Plugins → WartheMahl:

- **Nur vegetarische Gerichte** (= Schalter im Popout, `vegetarianOnly`)
- **Heutiges Gericht in der Bar** (`showTodayInBar`, Standard aus)
- **Aktualisierungsintervall** (`refreshIntervalMin`, Standard 60 min): wie alt
  der Cache sein darf, bevor beim Öffnen neu geladen wird

Gespeichert wird in der DMS-`settings.json` unter dem Plugin-Schlüssel.

## Aufbau

```
plugin.json            Manifest (type widget, settings, Berechtigungen)
WarthemahlWidget.qml   Bar-Pill + Popout (der einzige Einstiegspunkt)
Settings.qml           Einstellungs-UI (PluginSettings)
Model.js               Reine Hilfsfunktionen: Datum, Icons, Statustexte
bin/warthemahl-menu    Holt und parst die Seite, gibt JSON aus, cacht
tests/                 node --test für Model.js + QML-Verdrahtung, unittest für den Parser
```

Das HTML-Parsing liegt bewusst im Python-Helfer und nicht in QML: so lässt es
sich gegen eine gespeicherte Kopie der echten Seite testen, und eine Änderung an
der Website ist zu beheben, ohne das Widget anzufassen. Der Helfer gibt
**immer** genau ein JSON-Objekt aus und endet mit Status 0; Netzfehler liefern
den Cache mit `stale: true`.

## Tests

```bash
cd ~/projects/private/dms-plugins/warthemahl
node --test tests/model.test.js
python3 -B -m unittest discover -s tests
```

`-B` ist kein Detail: ohne das legt Python ein `__pycache__` im Plugin-Ordner
an, und der Dateiwächter der Shell lädt daraufhin jedes Mal das Plugin neu.

Die Parser-Tests laufen gegen `tests/fixtures/speisekarte.html`, eine echte
Kopie der Seite. Ändert WartheMahl das Seitenlayout: neue Kopie ziehen, Test
laufen lassen, `parse()` nachziehen.

```bash
curl -sL https://warthemahl.de/speisekarte/ -o tests/fixtures/speisekarte.html
```

## Lizenz

MIT, siehe [LICENSE](LICENSE). Die Speisekarten-Inhalte selbst gehören
WartheMahl und werden nur angezeigt, nicht mitgeliefert.
