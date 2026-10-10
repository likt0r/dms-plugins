# Umschalter

Eine Pille in der Bar-Mitte mit drei Umschaltern. Ersatz fuer Omarchys
`omarchy.indicators`.

| Zustand | Anzeige |
|---|---|
| nichts aktiv | nur ein gedimmter Anfasser (`...`) |
| etwas aktiv | nur die aktiven Icons, in Akzentfarbe |
| Zeiger darueber | alle drei, inaktive bei Deckkraft 0,45 |

| Umschalter | Icon | liest | Klick |
|---|---|---|---|
| Wachhalten | Kaffeetasse | `SessionService.idleInhibited` | `toggleIdleInhibit()` |
| VPN | Schloss | `NetworkService.vpnConnected` | oeffnet das vpnHub-Popout |
| Diktat | Mikrofon / Sanduhr | `$XDG_RUNTIME_DIR/voxtype/state` | `voxtype record toggle` |

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

**Nicht stoeren ist absichtlich nicht dabei:** der `notificationButton` rechts
zeigt denselben Zustand und kann mehr -- er zaehlt ungelesene Meldungen.

Rechtsklick auf die Pille oeffnet das Control Center.

## IPC

```
dms ipc call schalter status                 # welche aktiv sind
dms ipc call schalter toggle wach|vpn|diktat
dms ipc call schalter demo alle|nichts|wach|vpn|diktat|aus
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
