import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Kachel im Control Center fuer das Diktat. Wie aufnahmeKachel: nur Anzeige,
// Zustand und Schalten kommen aus der schalter-Gruppe (Begruendung dort, im
// Kopf von AufnahmeKachel.qml).
PluginComponent {
    id: root

    readonly property var gruppe: PluginService.getGlobalVar("schalter", "instanz", null)
    readonly property string zustand: root.gruppe?.diktatZustand || "idle"
    readonly property bool aktiv: root.gruppe ? root.gruppe.istAktiv("diktat") : false

    ccWidgetIcon: root.zustand === "transcribing" ? "hourglass_top" : "mic"
    ccWidgetPrimaryText: "Diktat"
    ccWidgetSecondaryText: {
        if (!root.gruppe)
            return "schalter-Gruppe fehlt"
        switch (root.zustand) {
        case "recording":
        case "streaming":
            return "Nimmt auf"
        case "transcribing":
            return "Transkribiert …"
        }
        return "Aus"
    }
    ccWidgetIsActive: root.aktiv

    // Control Center schliessen: solange es offen ist, haelt es den
    // Tastaturfokus, und voxtype tippte den Text ins Leere statt ins Fenster.
    onCcWidgetToggled: {
        PopoutService.closeControlCenter()
        if (root.gruppe)
            root.gruppe.schalten("diktat", null)
        else
            Quickshell.execDetached(["voxtype", "record", "toggle"])
    }
}
