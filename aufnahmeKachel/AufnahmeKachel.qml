import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Kachel im Control Center fuer die Bildschirmaufnahme. Zeigt nur an und
// reicht den Klick an die schalter-Gruppe in der Bar weiter -- dort liegen
// Zustand, HUD-Auswahl und Steuerung.
//
// Warum ein eigenes Plugin statt einer Kachel in schalter selbst: das Control
// Center legt fuer seine Kachel eine eigene Instanz der Plugin-Komponente an
// (DragDropGrid.qml, tryCreatePluginInstance), beim Auflisten sogar noch eine
// Wegwerf-Instanz (WidgetModel.qml). schalter mit IPC-Ziel, HUD und
// Dateiwaechtern liefe dann mehrfach. Diese Komponente ist leer genug, dass
// das nichts ausmacht.
PluginComponent {
    id: root

    // Die laufende schalter-Instanz, gemeldet in PluginService.globalVars
    // (SchalterWidget.qml, instanzMelden). null, solange die Gruppe nicht
    // geladen ist.
    readonly property var gruppe: PluginService.getGlobalVar("schalter", "instanz", null)
    readonly property bool aktiv: root.gruppe ? root.gruppe.istAktiv("aufnahme") : false

    ccWidgetIcon: "screen_record"
    ccWidgetPrimaryText: "Bildschirmaufnahme"
    ccWidgetSecondaryText: root.aktiv
        ? "Läuft · " + (root.gruppe?.aufnahmeDauer || "")
        : (root.gruppe ? "Aus" : "schalter-Gruppe fehlt")
    ccWidgetIsActive: root.aktiv

    // Das Control Center zuerst schliessen: die Auswahl erscheint als HUD
    // unten am Bildschirm, und eine Aufnahme soll es nicht mit drauf haben.
    onCcWidgetToggled: {
        PopoutService.closeControlCenter()
        if (root.gruppe)
            root.gruppe.schalten("aufnahme", null)
        else
            Quickshell.execDetached(["dms", "ipc", "call", "schalter", "toggle", "aufnahme"])
    }
}
