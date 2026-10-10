# Umschalter

Eine Pille in der Bar-Mitte mit fuenf Umschaltern. Ersatz fuer Omarchys
`omarchy.indicators`.

| Zustand | Anzeige |
|---|---|
| nichts aktiv | nur ein gedimmter Anfasser (`...`) |
| etwas aktiv | nur die aktiven Icons, in Akzentfarbe |
| Zeiger darueber | alle fuenf, inaktive bei Deckkraft 0,45 |

| Umschalter | Icon | liest | Klick |
|---|---|---|---|
| Wachhalten | Kaffeetasse | `SessionService.idleInhibited` | `toggleIdleInhibit()` |
| VPN | Schloss | `NetworkService.vpnConnected` | oeffnet das vpnHub-Popout |
| Diktat | Mikrofon / Sanduhr | `$XDG_RUNTIME_DIR/voxtype/state` | `voxtype record toggle` |
| Aufnahme | Bildschirm mit Punkt, rot + Laufzeit | `$XDG_RUNTIME_DIR/bildschirmaufnahme/state` | laeuft: stoppen, sonst HUD-Auswahl |
| Meldungen | Glocke (+ roter Punkt) / durchgestrichen | `NotificationService.unreadCount`, `SessionData.doNotDisturb` | Benachrichtigungszentrum; Mittelklick: Nicht stoeren |

VPN schaltet bewusst **nicht** selbst: welche der Verbindungen gemeint waere,
ist nicht zu erraten. Der Klick oeffnet das Popout von `vpnHub`, dort stehen
alle. Dessen Bar-Eintrag steht dafuer auf `enabled: false` -- das Plugin laeuft
weiter und sein Popout bleibt erreichbar, nur die Pille ist weg.

Damit das Popout **unter der Gruppe** herunterfaehrt und nicht am alten Platz
der vpnHub-Pille am rechten Rand, reichen wir die Stelle durch: `vpnHub` legt
seine Instanz je Schirm in `PluginService.globalVars` ab (Schluessel
`anker:<Schirmname>`), diese Gruppe holt sie dort und ruft `popoutAnkern(x, y,
breite)` direkt auf -- ohne `dms ipc call`, das einen Prozess startete und
immer nur die zuerst geladene Instanz traefe. Faellt der Weg aus (altes
`vpnHub`, Klick vor dem Laden), bleibt `dms ipc call vpnHub openPopout` als
Rueckfall, und das Popout geht wieder rechts auf.

**Meldungen ersetzen DMS' `notificationButton`** (dessen Bar-Eintrag steht auf
`enabled: false`). Aktiv -- also immer sichtbar -- ist die Glocke bei
Ungelesenem (roter Punkt) oder "Nicht stoeren" (durchgestrichen). Das
Benachrichtigungszentrum geht unter der Glocke auf: DMS' eigener Knopf nimmt
`DankBarContent.openWidgetPopout`, das Plugins nicht erreichen; hier laeuft es
wie beim VPN ueber `getPopupTriggerPosition` + `setTriggerPosition` am Popout
aus `PopoutService.notificationCenterPopout` (LazyLoader, `active = true`
legt es an). Die Dauer fuer "Nicht stoeren" waehlt man im Control Center
(Rechtsklick auf die Pille).

Rechtsklick auf die Pille oeffnet das Control Center.

## Bildschirmaufnahme

Aufgenommen wird in `~/.local/bin/bildschirmaufnahme` (dotfiles-Repo,
`localbin/`, gpu-screen-recorder). Ausgewaehlt wird im HUD unten am
Bildschirm, gebaut wie die Bildschirmauswahl auf F7 (`bildschirme`):

1. Modus: Bild, + Ton, + Mikro, + Mikro + Ton
2. Bildschirm (der fokussierte) oder Bereich (slurp)

- **F10** (`dms ipc call schalter aufnahme`): erster Druck oeffnet, jeder
  weitere wandert eine Kachel weiter, nach 1,2 s ohne Druck gilt sie. F10 und
  2,4 s warten heisst also: Bild, ganzer Bildschirm.
- **Klick** aufs Aufnahme-Icon: dasselbe HUD ohne Timer, die Kacheln nehmen
  Klicks an; ohne Wahl verschwindet es nach 8 s, Hover haelt es offen.
- **Tastatur**, solange das HUD offen ist: ←/→ (auch ↑/↓, Tab) waehlen und
  halten den Timer an, Enter uebernimmt, Backspace geht von Schritt 2 zurueck
  zum Modus, Esc bricht ab. Das HUD hat dafuer den Tastaturfokus, nur auf dem
  Schirm mit Fokus.
- Waehrend der Aufnahme stoppen F10 und der Klick direkt. Danach kurz
  "Aufnahme beendet", die Datei kommt als Benachrichtigung vom Skript.

Den Zustand liest die Gruppe per `FileView` aus der Zustandsdatei des
Skripts. Die muss beim Laden schon existieren, sonst meldet der Waechter
nie etwas -- fehlt sie, legt das Plugin sie leer an und laedt neu.

## IPC

```
dms ipc call schalter status                 # welche aktiv sind
dms ipc call schalter toggle wach|vpn|diktat|aufnahme|meldungen
dms ipc call schalter demo alle|nichts|wach|vpn|diktat|aufnahme|meldungen|aus
dms ipc call schalter aufnahme               # F10: HUD bzw. stoppen
dms ipc call schalter osd aufnahme           # nur das HUD zeigen (8 s)
```

`demo` taeuscht Zustaende nur fuer die Anzeige vor und schaltet nichts; nach
30 s endet er von selbst, damit ein vergessener Testmodus nichts dauerhaft
behauptet. `nichts` ist dabei eigens noetig, weil sich der Anfasser sonst nie
pruefen laesst, solange irgendetwas echt an ist.

## Warum nicht der eingebaute ControlCenterButton

DMS bringt mit `ControlCenterButton` einen fast gleichen Cluster mit, der
`idleInhibitor`, `doNotDisturb` und `vpn` kennt (beide per Default aus,
`SettingsData.qml:418-419`). Drei Dinge fehlen ihm, keines nachruestbar:
seine Gruppenliste ist fest einkompiliert, Plugins koennen nichts beisteuern
(also kein Diktat); er klappt nicht auf; und ein Klick oeffnet das Control
Center, statt zu schalten.

Wer die beiden dort spaeter einschaltet, sieht die Icons doppelt. Abschalten
geht per IPC, es sind Booleans:
`dms ipc call settings set controlCenterShowIdleInhibitorIcon false`.

## Zwei Entscheidungen, die man nicht aendern sollte, ohne das hier gelesen zu haben

**Die Gruppe gehoert ans ENDE der Center-Sektion.** DMS nagelt im Modus
`index` das mittlere konfigurierte Widget an die Bildschirmmitte und laesst
den Rest nach aussen fliessen (`CenterSection.qml:155-186`). Als letztes
Widget steht die linke Kante der Pille fest, sie waechst beim Aufklappen nur
nach rechts -- kein Nachbar bewegt sich. Steht die Gruppe woanders, schiebt
das Aufklappen die rechts davon stehenden Widgets weg; dann kann der Zeiger
unter einem wandernden Nachbarn landen, das klappt sofort wieder zu und
flackert. Omarchy faengt genau das mit einer 120-ms-Hysterese ab -- die
braucht es hier nur, wenn die Gruppe ihren Platz verliert.

**Inaktive Plaetze brauchen `visible: false`, nicht `width: 0`.** Ein Kind mit
`visible: true` und Breite 0 zieht im `Row` trotzdem sein Spacing mit; drei
versteckte Schalter liessen so 8 px Totraum stehen.

## Hover und Klick in einer Pille

`BasePill` legt seine eigene MouseArea auf `z: -1`, also hinter den Inhalt.
Deshalb funktionieren eigene Klickflaechen je Icon. Die Flaeche fuer den
Gruppen-Hover liegt als erstes Kind darunter und hat
`acceptedButtons: Qt.NoButton` -- sie meldet nur Hover und schluckt keine
Klicks. Die Icon-Flaechen haben bewusst `hoverEnabled: false`: sonst zoegen
sie den Hover von der Gruppenflaeche ab und die aufgedeckten Icons flackerten
beim Darueberfahren.
