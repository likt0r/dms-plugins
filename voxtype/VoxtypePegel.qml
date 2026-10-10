import QtQuick
import Quickshell.Io

// Mikrofonpegel fuers Diktat-OSD, aus voxtypes eigenem Audio-Socket.
//
// Der Daemon schreibt Audio-Frames nach $XDG_RUNTIME_DIR/voxtype/audio.sock;
// der mitgelieferte Sidecar `voxtype-audio-bridge` uebersetzt das nach NDJSON:
//   {"peak":0.421,"rms":0.180,"vad":1,"ts_ms":1234567}
//   {"status":"connected"} / {"status":"disconnected"}
//
// Warum nicht /usr/share/voxtype/quickshell/voxtype-shared/AudioBridge.qml,
// das es fertig gibt: dort steht `running: true` fest verdrahtet (Zeile 126),
// der Sidecar liefe also rund um die Uhr statt nur waehrend der Aufnahme. Und
// es schreibt pro Frame vier QML-Properties -- bei gemessenen 102 Hz sind das
// ~400 Binding-Auswertungen pro Sekunde in jedem angehaengten Delegate.
// Deshalb hier eine eigene Fassung mit zwei Unterschieden: der Prozess haengt
// am Aufnahmezustand, und die Frames landen in einem nackten JS-Objekt, das
// keine Bindings weckt. Abgeholt wird im Takt der Anzeige.
//
// Das Protokoll ist laut voxtype-Doku festgeschrieben ("locked protocol").
Item {
    id: root

    property bool aktiv: false
    property string binary: "voxtype-audio-bridge"

    readonly property bool sollLaufen: root.aktiv && !root.fehlt
    // Nach drei Fehlstarts in Folge gilt der Sidecar als nicht benutzbar
    // (fehlendes Paket, falsches Prefix). Dann nicht weiter im Sekundentakt
    // neu starten -- das OSD zeigt die Phase dann eben ohne Balken.
    property bool fehlt: false
    property bool verbunden: false
    property int _fehler: 0

    // Absichtlich ein nacktes JS-Objekt: In-place-Mutation loest kein
    // propertyChanged aus, 100 Frames/s kosten damit nichts.
    property var _akku: ({ max: 0, stimme: false, frames: 0 })

    // Groesster Pegel und Sprach-Flag seit dem letzten Abholen.
    function abholenUndLeeren() {
        const w = { max: root._akku.max, stimme: root._akku.stimme, frames: root._akku.frames }
        root._akku.max = 0
        root._akku.stimme = false
        root._akku.frames = 0
        return w
    }

    onAktivChanged: {
        if (root.aktiv) {
            root._fehler = 0
            root.fehlt = false
        } else {
            root.verbunden = false
        }
        root.abholenUndLeeren()
    }

    onSollLaufenChanged: proc.running = root.sollLaufen

    Process {
        id: proc

        command: [root.binary]

        stdout: SplitParser {
            onRead: zeile => {
                try {
                    const j = JSON.parse(zeile)
                    if (j.status !== undefined) {
                        root.verbunden = j.status === "connected"
                        return
                    }
                    if (j.peak === undefined)
                        return
                    const a = root._akku
                    if (j.peak > a.max)
                        a.max = j.peak
                    if (j.vad)
                        a.stimme = true
                    a.frames++
                } catch (e) {
                    // Die Bridge loggt auf stderr, hier kommt nur NDJSON an --
                    // eine kaputte Zeile ist kein Grund, den Strom aufzugeben.
                }
            }
        }

        onExited: {
            root.verbunden = false
            if (!root.sollLaufen)
                return
            root._fehler++
            if (root._fehler >= 3) {
                root.fehlt = true
                return
            }
            neustart.restart()
        }
    }

    Timer {
        id: neustart
        interval: 1000
        onTriggered: proc.running = root.sollLaufen
    }
}
