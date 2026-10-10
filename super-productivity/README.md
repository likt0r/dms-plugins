# Todos (Super Productivity)

Todos in der DankMaterialShell-Bar, mit [Super Productivity](https://super-productivity.com)
als Backend. Die Pille zeigt, wie viel heute ansteht. Ein Klick oder Super+M
klappt darunter ein Popout von oben auf, wie bei Benachrichtigungen oder WLAN.
Dort legt man Tasks an und hakt sie ab. Geht ein anderes Popout auf
(Kontrollzentrum, WLAN, Benachrichtigungen …), schließt sich das Todo-Popout
und umgekehrt. Das regelt DMS selbst.

Die Daten bleiben in Super Productivity. Das Plugin spricht nur mit dessen
**lokaler REST-API** und speichert selbst nichts. Den Sync (bei mir per
WebDAV zu OpenCloud) erledigt die App.

## Voraussetzungen

- Super Productivity als **Desktop-App** (die API gibt es weder im Web noch
  auf dem Handy), hier als Flatpak `com.super_productivity.SuperProductivity`.
- In SP unter Einstellungen → Sonstiges: **„Enable local REST API“** an. SP
  lauscht dann auf `127.0.0.1:3876` und legt ein Token in
  `~/.var/app/com.super_productivity.SuperProductivity/config/superProductivity/local-rest-api-token`
  ab (bei RPM/AppImage unter `~/.config/superProductivity/`). Das Plugin
  liest es dort selbst, man muss nichts abtippen.
- Ebenda **„Anwendung als Trayicon minimieren“** an. Sonst beendet das
  Schließen des Fensters die App und mit ihr die API.
- `curl`.

SP muss laufen. Im dotfiles-Repo startet `niri/hosts/<host>.kdl` es beim
Login und schiebt das Fenster ungefokusst auf Workspace 9. Einen versteckten
Start kennt SP 19 nicht.

## Bedienung

**Bar:** Das Icon zeigt die Zahl offener Tasks, je nach Einstellung für heute
(fällig und überfällig) oder alle. Läuft die Zeiterfassung, wird das Icon zur
Uhr, und der Task steht daneben. Ein **Klick** (oder **Super+M**, siehe
`niri/config.kdl` im dotfiles-Repo) öffnet und schließt das Popout, ein
**Rechtsklick** holt SP nach vorn. Im Kopf des Popouts stehen die Zähler
bzw. der laufende Task sowie Knöpfe für Neu laden und SP öffnen.

**Popout:**

- Chips oben: *Heute*, *Alle* und je ein Chip pro Projekt, jeweils mit der
  Zahl offener Tasks.
- Eingabefeld: Enter legt einen Task an.
  - Unter *Heute* bekommt er `dueDay = heute` und landet im Standardprojekt
    (Einstellung, sonst Inbox).
  - Unter *Alle* landet er im Standardprojekt.
  - Unter einem Projekt landet er in diesem Projekt.
  - Das Ziel steht im Platzhalter.
- Checkbox: abhaken bzw. zurückholen.
- **Doppelklick** auf einen Titel benennt den Task um (Enter speichert, Esc
  bricht ab).
- Beim Überfahren erscheinen ▶/■ für die Zeiterfassung und ein Papierkorb.
  Löschen braucht zwei Klicks, weil die API kein Rückgängig kennt.
- Bei *Heute* und *Alle* sind die Tasks nach Projekt gruppiert, in der
  Reihenfolge wie in SP. Unteraufgaben stehen eingerückt darunter.
- *Erledigt (n)* am Ende klappt die erledigten Tasks auf. Unter *Heute* sind
  das die heute erledigten.
- Läuft SP nicht, zeigt das Popout einen Startknopf statt der Liste.

Esc schließt das Popout. Das Eingabefeld hat beim Öffnen den Fokus, man kann
also direkt lostippen.

## IPC

```sh
dms ipc call superProductivity toggle        # Popout auf/zu (an der Pille)
dms ipc call superProductivity add "Milch"   # Task im aktuellen Filter anlegen
dms ipc call superProductivity refresh
dms ipc call superProductivity status        # "2 heute, 11 offen, läuft: …"
```

Das Tastenkürzel in `niri/config.kdl`:
`Mod+M { spawn "dms" "ipc" "call" "superProductivity" "toggle"; }`.

Für den IPC gelten zwei Fallen wie bei den anderen Plugins:

- Bei mehreren Bars antwortet die zuerst registrierte Instanz.
- Nach `plugins reload` hängt das Target an der alten Instanz, dann hilft
  nur `systemctl --user restart dms.service`.

## Abgleich

Die API kennt keine Push-Nachrichten. Das Plugin fragt deshalb bei SP nach:

- alle *Abgleich im Hintergrund* Sekunden (Standard 60),
- alle 10 s, solange das Popout offen ist,
- bei jedem Öffnen.

Eigene Änderungen erscheinen sofort, danach gleicht das Plugin mit dem
echten Stand ab. Während einer Umbenennung pausiert der Abgleich, damit er
das Eingabefeld nicht wegwirft.

## Aufbau

```
TodoWidget.qml   Pille, Popout, Anfragen, IPC
Model.js         Datenlogik: Heute/überfällig, Gruppierung, Chips, POST-Bodies
Settings.qml     Einstellungen
bin/sp-api       ein API-Aufruf: sp-api METHOD PFAD [JSON]
tests/           node --test für Model.js und die Verdrahtung
```

`bin/sp-api` gibt immer ein JSON-Objekt `{"ok":…}` aus, auch wenn SP nicht
läuft (`OFFLINE`), das Token fehlt (`NO_TOKEN`) oder SP hängt (`TIMEOUT`).
Das Widget kennt damit nur einen Fehlerpfad. Das Token geht per
`curl -K -` über stdin an curl und steht dadurch nicht in der
Prozessliste. SP weist Anfragen mit `Origin`-Header ab (Schutz gegen CSRF aus
dem Browser), deshalb laufen die Aufrufe über curl und nicht per XHR aus QML.

Verwendete Endpunkte, aus dem Quellcode von SP 19.1 gelesen (eine offizielle
Referenz gibt es nicht):

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/tasks?includeDone=true` | alle Tasks (aktiv, nicht archiviert) |
| POST | `/tasks` | anlegen: `title`, `projectId`, `dueDay`, … |
| PATCH | `/tasks/:id` | `isDone`, `title` |
| DELETE | `/tasks/:id` | löschen (mit Unteraufgaben) |
| POST | `/tasks/:id/start` | Zeiterfassung starten |
| POST | `/task-control/stop` | Zeiterfassung stoppen |
| GET | `/task-control/current` | laufender Task |
| GET | `/projects` | Projekte (Name, Farbe, Reihenfolge) |

„Heute“ rechnet das Plugin wie SP selbst: `dueWithTime` innerhalb des Tages,
sonst `dueDay` gleich heute. Überfällige Tasks zeigt es zusätzlich an.

## Tests

```sh
node --test tests/model.test.js
```
