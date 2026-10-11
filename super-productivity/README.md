# Todos (Super Productivity)

Todos in der DankMaterialShell-Bar, mit [Super Productivity](https://super-productivity.com)
als Backend. Die Pille zeigt, wie viel heute ansteht. Ein Klick oder Super+M
klappt von der Bildschirmkante ein Panel herein, wie das Notepad von DMS. Dort
legt man Tasks an, hakt sie ab und schreibt Notizen dazu. Geht ein Popout auf
(Kontrollzentrum, WLAN, VPN …), liegt es über dem Panel, und das Panel bleibt
offen.

Dafür meldet sich das Panel nicht beim `PopoutManager` von DMS an, und es liegt
fest auf dem Layer `Top`. Im Frame-Modus würde `DankSlideout` sonst auf
`Overlay` gehen, also über die Popouts.

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

SP muss laufen. Im dotfiles-Repo läuft es als systemd-User-Dienst
(`systemd/user/super-productivity.service`, `Restart=always`), und eine
niri-Regel legt das Fenster ungefokusst auf Workspace 9. Ganz ohne Fenster
geht es nicht: Die REST-API beantwortet die Angular-Oberfläche von SP, nicht
der Electron-Hauptprozess. Einen versteckten Start kennt SP 19 auch nicht.

## Bedienung

**Bar:** Das Icon zeigt die Zahl offener Tasks, je nach Einstellung für heute
(fällig und überfällig) oder alle. Läuft die Zeiterfassung, wird das Icon zur
Uhr, und der Task steht daneben. Ein **Klick** (oder **Super+M**, siehe
`niri/config.kdl` im dotfiles-Repo) öffnet und schließt das Panel, ein
**Rechtsklick** holt SP nach vorn. Im Kopf des Panels stehen die Zähler
bzw. der laufende Task sowie Knöpfe für Neu laden, SP öffnen und Schließen.
Die Seite (rechts/links) und die Breite stehen in den Einstellungen.

**Panel:**

- Chips oben: *Heute*, *Alle* und je ein Chip pro Projekt, jeweils mit der
  Zahl offener Tasks.
- Eingabefeld: Enter legt einen Task an.
  - Unter *Heute* bekommt er `dueDay = heute` und landet im Standardprojekt
    (Einstellung, sonst Inbox).
  - Unter *Alle* landet er im Standardprojekt.
  - Unter einem Projekt landet er in diesem Projekt.
  - Das Ziel steht im Platzhalter.
- Checkbox: abhaken bzw. zurückholen.
- **Klick** auf einen Titel klappt den Task auf. Darunter stehen seine
  **Notizen**, formatiert angezeigt (sie sind in SP Markdown: Listen, fett,
  Checklisten, Links). Ein Klick in die Notiz schaltet auf das rohe Markdown
  zum Bearbeiten. Gespeichert wird 800 ms nach der letzten Eingabe, beim
  Verlassen des Felds, mit Esc und beim Schließen des Panels. Links öffnen per
  `xdg-open`. Ein Notiz-Marker direkt hinter dem Titel zeigt, dass ein Task
  Notizen hat; ein Klick darauf klappt ihn auf.
- **Projekt-Notizen** markiert ein Notiz-Icon (mit Zahl ab zwei) neben der
  Projekt-Kopfzeile bzw. unter einem Projekt-Chip über der Liste. Lesen kann
  das Plugin sie nicht: die API liefert pro Projekt nur `noteIds`, eine Route
  für Notizen gibt es nicht. Ein Klick auf den Marker holt deshalb SP nach
  vorn.
- **Doppelklick** auf einen Titel benennt den Task um (Enter speichert, Esc
  bricht ab).
- Beim Überfahren erscheinen ▶/■ für die Zeiterfassung und ein Papierkorb.
  Löschen braucht zwei Klicks, weil die API kein Rückgängig kennt.
- Bei *Heute* und *Alle* sind die Tasks nach Projekt gruppiert, in der
  Reihenfolge wie in SP. Unteraufgaben stehen eingerückt darunter.
- *Erledigt (n)* am Ende klappt die erledigten Tasks auf. Unter *Heute* sind
  das die heute erledigten.
- Läuft SP nicht, zeigt das Panel einen Startknopf statt der Liste.

Esc schließt das Panel; im Notizfeld klappt Esc nur die Bearbeitung zu. Das Eingabefeld hat beim Öffnen den Fokus, man kann
also direkt lostippen.

## IPC

```sh
dms ipc call superProductivity toggle        # Panel auf/zu (fokussierter Schirm)
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
- alle 10 s, solange das Panel offen ist (nicht während eine Notiz
  bearbeitet wird),
- bei jedem Öffnen.

Eigene Änderungen erscheinen sofort, danach gleicht das Plugin mit dem
echten Stand ab. Während einer Umbenennung pausiert der Abgleich, damit er
das Eingabefeld nicht wegwirft.

## Aufbau

```
TodoWidget.qml   Pille, Slideout mit Notizen, Anfragen, IPC
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
