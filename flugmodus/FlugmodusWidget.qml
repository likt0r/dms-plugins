import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Ein Flugzeug in der Bar, solange der Flugmodus laeuft -- sonst gar nichts --
// und beim Umschalten dasselbe OSD unten am Bildschirm wie bei Lautstaerke
// und Helligkeit. Klick aufs Icon schaltet ihn aus (dasselbe Skript wie F8).
//
// Der Zustand wird nicht gepollt: DMSNetworkService und BluetoothService
// schieben ihre Aenderungen selbst. Flugmodus heisst hier "Funk aus UND kein
// Bluetooth-Adapter mehr da" -- beim Sperren des ThinkPad-Schalters
// verschwindet hci0, deshalb available statt enabled. Beides zusammen, damit
// ein blosses WLAN-Aus im Control Center nicht als Flugmodus durchgeht.
PluginComponent {
    id: root

    property var popoutService: null

    Ref { service: DMSNetworkService }
    Ref { service: BluetoothService }

    readonly property bool aktiv: !DMSNetworkService.wifiEnabled && !BluetoothService.available

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    // Der erste Durchlauf beim Start zaehlt nicht, sonst blitzte das OSD bei
    // jedem Shell-Start auf.
    property bool zustandBekannt: false

    signal osdZeigen

    // setVisibilityOverride faehrt die Pille ueber effectiveVisible auf
    // Breite 0 (PluginComponent.qml:211-226, states + PropertyChanges). Die
    // nullbreite Pille unten ist deshalb nicht noetig -- sie schadet nur
    // nicht. Uebrig bleibt so oder so das Spacing der Sektion (~4 px), weil
    // das Delegate in RightSection.qml:60 seine Sichtbarkeit an
    // "active && widgetEnabled" haengt, nicht am Item. Ganz weg bekommt man
    // ein Widget nur mit {"id": ..., "enabled": false} im Bar-Eintrag.
    onAktivChanged: {
        root.setVisibilityOverride(root.aktiv)
        if (root.zustandBekannt)
            root.osdZeigen()
    }

    Component.onCompleted: {
        root.setVisibilityOverride(root.aktiv)
        root.zustandBekannt = true
    }

    // Steuerung und Test von aussen:
    //   dms ipc call flugmodus toggle   schaltet wie die Taste F8
    //   dms ipc call flugmodus status   "an" / "aus"
    //   dms ipc call flugmodus osd      zeigt nur das OSD, ohne den Funk
    //                                   anzufassen -- zum Pruefen von Sitz
    //                                   und Aussehen
    IpcHandler {
        target: "flugmodus"

        function toggle(): string {
            Quickshell.execDetached(["sh", "-c", "exec \"$HOME/.local/bin/flugmodus\""])
            return "ok"
        }

        function status(): string {
            return root.aktiv ? "an" : "aus"
        }

        function osd(): string {
            root.osdZeigen()
            return "ok"
        }
    }

    pillClickAction: () => Quickshell.execDetached(
        ["sh", "-c", "exec \"$HOME/.local/bin/flugmodus\""])

    // Wie in DMSShell.qml: ein OSD pro Bildschirm ueber Variants. Ein einzelnes
    // DankOSD mit modelData: root.parentScreen geht nicht -- parentScreen ist
    // in Plugin-Widgets null, und ohne Screen bleibt das Fenster ohne
    // Geometrie (500x500, Position undefiniert) unsichtbar.
    // Bei mehreren Bars auf mehreren Schirmen gaebe es die OSDs doppelt; hier
    // laeuft eine Bar.
    Variants {
        model: SettingsData.getFilteredScreens("osd")

        delegate: DankOSD {
            id: osd

            osdWidth: Math.min(Math.max(120, Theme.iconSize + beschriftung.width + Theme.spacingS * 4),
                               screenWidth - Theme.spacingM * 2)
            osdHeight: 40 + Theme.spacingS * 2
            autoHideInterval: 2000
            enableMouseInteraction: false

            Connections {
                target: root
                function onOsdZeigen() {
                    osd.show()
                }
            }

            // An den laengeren der beiden Texte gehaengt, damit die Breite
            // beim Umschalten nicht springt.
            TextMetrics {
                id: beschriftung
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                font.family: Theme.fontFamily
                text: "Flugmodus aus"
            }

            content: Item {
                property int abstand: Theme.spacingS

                anchors.centerIn: parent
                width: parent.width - Theme.spacingS * 2
                height: 40

                DankIcon {
                    x: parent.abstand
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.aktiv ? "airplanemode_active" : "airplanemode_inactive"
                    size: Theme.iconSize
                    color: Theme.primary
                }

                StyledText {
                    x: parent.abstand * 2 + Theme.iconSize
                    width: parent.width - Theme.iconSize - parent.abstand * 3
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.aktiv ? "Flugmodus an" : "Flugmodus aus"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }
            }
        }
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: root.aktiv ? flieger.width : 0
            implicitHeight: root.aktiv ? flieger.height : 0
            visible: root.aktiv

            DankIcon {
                id: flieger
                anchors.centerIn: parent
                name: "airplanemode_active"
                color: Theme.widgetTextColor
                size: root.barIconPx
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: root.aktiv ? fliegerV.width : 0
            implicitHeight: root.aktiv ? fliegerV.height : 0
            visible: root.aktiv

            DankIcon {
                id: fliegerV
                anchors.centerIn: parent
                name: "airplanemode_active"
                color: Theme.widgetTextColor
                size: root.barIconPx
            }
        }
    }
}
