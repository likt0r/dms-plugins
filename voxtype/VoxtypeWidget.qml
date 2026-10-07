import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Diktat-Status in der Bar. Ersatz fuer Omarchys Dictation.qml und fuer das
// von `voxtype setup dms --install` generierte Widget (das zielt auf ein
// DMS ohne Plugin-Manifest und eine Process-API, die es in Quickshell nicht
// gibt). Status kommt als JSON-Zeilenstrom aus
// `voxtype status --follow --extended --format json`.
PluginComponent {
    id: root

    property string dictState: "stopped"
    property string statusTooltip: "Voxtype laeuft nicht"

    readonly property string stateIcon: ({
        "idle": "mic",
        "recording": "fiber_manual_record",
        "transcribing": "hourglass_top"
    })[dictState] || "mic_off"

    // Aktiv (Aufnahme/Transkription) in der System-Akzentfarbe, sonst wie
    // die uebrigen Bar-Icons (Theme.widgetTextColor) -- kein rot/orange.
    readonly property bool isActive: dictState === "recording" || dictState === "transcribing"
    readonly property color stateColor: isActive ? Theme.primary : Theme.widgetTextColor

    // Gleiche Icon-Groesse wie die eingebauten Widgets (z.B. IdleInhibitor).
    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    // Pill nur zeigen, wenn der Daemon laeuft. Nicht pgrep -x voxtype:
    // seit dem offiziellen RPM heisst der Prozess nach Variante, z.B.
    // voxtype-avx512 oder voxtype-vulkan.
    visibilityCommand: "systemctl --user --quiet is-active voxtype.service"
    visibilityInterval: 10

    pillClickAction: () => {
        Quickshell.execDetached(["voxtype", "record", "toggle"])
    }
    // Konfiguration im schwebenden Terminal (Fensterregel in niri/config.kdl).
    pillRightClickAction: () => {
        Quickshell.execDetached(["alacritty", "--class", "voxtype-configure", "-e", "voxtype", "configure"])
    }

    Process {
        id: statusProcess
        command: ["voxtype", "status", "--follow", "--extended", "--format", "json"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    const j = JSON.parse(data)
                    root.dictState = String(j["class"] || "stopped")
                    root.statusTooltip = String(j.tooltip || "")
                } catch (e) {}
            }
        }
        // Daemon weg -> Strom endet. Zustand zuruecksetzen und spaeter neu
        // verbinden (der Daemon kommt per systemd meist wieder).
        onExited: {
            root.dictState = "stopped"
            restartTimer.start()
        }
    }

    Timer {
        id: restartTimer
        interval: 5000
        onTriggered: statusProcess.running = true
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: pillIcon.width
            implicitHeight: pillIcon.height

            DankIcon {
                id: pillIcon
                anchors.centerIn: parent
                name: root.stateIcon
                color: root.stateColor
                size: root.barIconPx

                SequentialAnimation on opacity {
                    running: root.dictState === "recording" && root.surfaceLive
                    loops: Animation.Infinite
                    onStopped: pillIcon.opacity = 1
                    NumberAnimation { to: 0.4; duration: 500; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: pillIconV.width
            implicitHeight: pillIconV.height

            DankIcon {
                id: pillIconV
                anchors.centerIn: parent
                name: root.stateIcon
                color: root.stateColor
                size: root.barIconPx

                SequentialAnimation on opacity {
                    running: root.dictState === "recording" && root.surfaceLive
                    loops: Animation.Infinite
                    onStopped: pillIconV.opacity = 1
                    NumberAnimation { to: 0.4; duration: 500; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
                }
            }
        }
    }
}
