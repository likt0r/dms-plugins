import QtQuick
import Quickshell
import Quickshell.Io
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
        if (root.gruppe) {
            root.gruppe.schalten("diktat", null)
        } else {
            // Anders als die Aufnahme braucht das Diktat die Gruppe nicht:
            // voxtype direkt schalten, nur nicht mehr blind.
            root.protokoll("schalter-Gruppe nicht geladen, schalte voxtype direkt")
            if (!rueckfall.running)
                rueckfall.running = true
        }
    }

    // journalctl --user -u dms -g '\[diktatKachel\]'
    function protokoll(text) {
        console.warn("[diktatKachel] " + text)
    }

    function melden(titel, text) {
        root.protokoll(titel + " – " + text)
        Quickshell.execDetached(["notify-send", "-a", "Diktat", "-i", "audio-input-microphone",
            "-u", "normal", titel, text])
    }

    // Ueber sh, damit ein fehlendes voxtype mit Exit 127 endet statt gar
    // nicht zu starten (dann kaeme kein onExited).
    Process {
        id: rueckfall
        command: ["sh", "-c", "exec voxtype record toggle"]
        stderr: StdioCollector {
            id: rueckfallErr
            waitForEnd: true
        }
        onExited: (exitCode) => Qt.callLater(() => {
            if (exitCode === 0)
                return
            root.protokoll("voxtype record toggle -> Exit " + exitCode + "\n" + rueckfallErr.text.trim())
            const zeilen = rueckfallErr.text.trim().split("\n")
            root.melden("Diktat ließ sich nicht schalten", zeilen[zeilen.length - 1] || ("Exit " + exitCode))
        })
    }
}
