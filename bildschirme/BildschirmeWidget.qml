import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Bildschirmmodus umschalten wie GNOMEs Super+P: ein Popout mit allen Modi,
// der aktive markiert. Gedacht fuer die Anzeige-Sondertaste (ThinkPad F7,
// Keysym XF86Display), gebunden in niri/config.kdl als
//   dms ipc call bildschirme taste
// Ein Druck oeffnet das Popout, jeder weitere schaltet eine Stufe weiter --
// das Popout zeigt dabei live, wo man steht. Esc oder Klick daneben schliesst.
// Pfeiltasten gibt es nicht: DMS-Popouts haben keinen KeyCatcher.
//
// Geschaltet wird nicht hier, sondern in ~/.local/bin/monitor-modus
// (dotfiles-Repo, localbin/). Dort steht auch, warum Spiegeln ueber wl-mirror
// laeuft: niri 26.04 kann es nicht und hat es nicht geplant.
PluginComponent {
    id: root

    property var popoutService: null

    // Kompletter Zustand aus "monitor-modus status" -- eine Quelle, damit
    // Bar-Icon und Popout nie Unterschiedliches behaupten.
    property var zustand: ({ modus: "alle", outputs: [], profile: [], spiegelbar: false })
    // Ob das Popout offen ist, weiss nur das Popout selbst: pluginPopout ist
    // eine id in PluginComponent.qml und von hier aus nicht erreichbar.
    property bool popoutOffen: false
    // Der erste gelesene Zustand ist kein Wechsel -- sonst blitzte das OSD
    // bei jedem Shell-Start auf.
    property string letzterModus: ""

    signal osdZeigen

    readonly property string modus: root.zustand.modus || "alle"
    readonly property var externe: (root.zustand.outputs || []).filter(o => !o.intern)
    readonly property bool hatExtern: root.externe.length > 0
    readonly property bool spiegelbar: root.hatExtern && root.zustand.spiegelbar === true
    readonly property var profile: root.zustand.profile || []

    readonly property var modi: [
        {
            id: "alle",
            label: "Alle Bildschirme",
            icon: "devices",
            frei: root.hatExtern,
            grund: "Nur ein Bildschirm angeschlossen"
        },
        {
            id: "extern",
            label: "Nur extern",
            icon: "monitor",
            frei: root.hatExtern,
            grund: "Kein externer Bildschirm angeschlossen"
        },
        {
            id: "intern",
            label: "Nur intern",
            icon: "laptop",
            frei: true,
            grund: ""
        },
        {
            id: "spiegeln",
            label: "Spiegeln",
            icon: "screen_share",
            frei: root.spiegelbar,
            grund: root.hatExtern ? "Braucht wl-mirror (dnf install wl-mirror)"
                                  : "Kein externer Bildschirm angeschlossen"
        }
    ]

    readonly property var aktiverModus: root.modi.find(m => m.id === root.modus) || root.modi[0]
    readonly property string modusLabel: root.aktiverModus.label

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    popoutWidth: 380

    // Argumente einzeln durchreichen statt in eine Shell-Zeile kleben --
    // Profilnamen wie "Anna Wohnzimmer" haben Leerzeichen.
    function helfer(args) {
        return ["sh", "-c", "exec \"$HOME/.local/bin/monitor-modus\" \"$@\"", "sh"].concat(args)
    }

    function laden() {
        if (statusProc.running)
            return
        statusProc.running = true
    }

    function uebernehmen(text) {
        try {
            const neu = JSON.parse(text)
            if (neu && neu.modus) {
                root.zustand = neu
                if (root.letzterModus !== "" && root.letzterModus !== neu.modus)
                    root.osdZeigen()
                root.letzterModus = neu.modus
            }
        } catch (e) {
            // Kaputte Ausgabe lieber ignorieren als den letzten guten Stand
            // durch eine leere Liste ersetzen.
        }
    }

    function ausfuehren(args) {
        if (aktionProc.running)
            return
        aktionProc.command = root.helfer(args)
        aktionProc.running = true
    }

    function setzen(id) {
        root.ausfuehren([id])
    }

    function profilSetzen(name) {
        root.ausfuehren(["profil", name])
    }

    // Eine Stufe weiter, aber nur ueber das, was gerade moeglich ist: ohne
    // zweiten Schirm bleibt genau "intern" uebrig, dann dreht sich nichts.
    function weiter() {
        const frei = root.modi.filter(m => m.frei)
        if (frei.length < 2) {
            ToastService?.showWarning("Kein externer Bildschirm angeschlossen")
            return
        }
        const i = frei.findIndex(m => m.id === root.modus)
        root.setzen(frei[(i + 1) % frei.length].id)
    }

    function einstellungenOeffnen() {
        Quickshell.execDetached(["dms", "ipc", "call", "settings", "openWith", "displays"])
    }

    pillRightClickAction: () => root.weiter()

    Component.onCompleted: root.laden()

    // Steuerung von aussen (Keybind in niri/config.kdl):
    //   dms ipc call bildschirme taste        F7: oeffnen, dann weiterschalten
    //   dms ipc call bildschirme toggle       nur das Popout
    //   dms ipc call bildschirme waehle <modus>
    //   dms ipc call bildschirme weiter
    //   dms ipc call bildschirme status
    // Bei mehreren Monitoren antwortet die zuerst registrierte Bar-Instanz;
    // nach "dms ipc call plugins reload bildschirme" haengt das Target an der
    // alten Instanz (quickshell#898), dann hilft nur ein Shell-Neustart.
    IpcHandler {
        target: "bildschirme"

        function taste(): string {
            if (root.popoutOffen) {
                root.weiter()
                return "weiter"
            }
            root.triggerPopout()
            return "offen"
        }

        function toggle(): string {
            root.triggerPopout()
            return "ok"
        }

        function waehle(modus: string): string {
            const treffer = root.modi.find(m => m.id === modus)
            if (!treffer)
                return "unbekannter Modus: " + modus
            if (!treffer.frei)
                return treffer.grund
            root.setzen(modus)
            return "ok"
        }

        function weiter(): string {
            root.weiter()
            return "ok"
        }

        function status(): string {
            return root.modusLabel
        }

        // Zeigt nur das OSD, ohne etwas umzuschalten -- zum Pruefen von Sitz
        // und Aussehen.
        function osd(): string {
            root.osdZeigen()
            return "ok"
        }
    }

    Process {
        id: statusProc
        command: root.helfer(["status"])
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.uebernehmen(text)
        }
        stderr: StdioCollector { waitForEnd: true }
    }

    Process {
        id: aktionProc
        // Nach dem Schalten nachlesen statt raten -- wl-mirror braucht einen
        // Moment, bis pgrep ihn sieht.
        onExited: nachlauf.restart()
    }

    Timer {
        id: nachlauf
        interval: 400
        onTriggered: root.laden()
    }

    // Offenes Popout bleibt aktuell (Kabel rein, Kabel raus); geschlossen
    // reicht ein gemaechlicher Takt fuers Bar-Icon.
    Timer {
        interval: root.popoutOffen ? 2000 : 30000
        running: true
        repeat: true
        onTriggered: root.laden()
    }

    // Wie in DMSShell.qml: ein OSD pro Bildschirm ueber Variants. Ein einzelnes
    // DankOSD mit modelData: root.parentScreen geht nicht -- parentScreen ist
    // in Plugin-Widgets null, und ohne Screen bleibt das Fenster ohne
    // Geometrie unsichtbar.
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

            // An den laengsten Modusnamen gehaengt, damit die Breite beim
            // Durchschalten nicht springt.
            TextMetrics {
                id: beschriftung
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                font.family: Theme.fontFamily
                text: "Alle Bildschirme"
            }

            content: Item {
                property int abstand: Theme.spacingS

                anchors.centerIn: parent
                width: parent.width - Theme.spacingS * 2
                height: 40

                DankIcon {
                    x: parent.abstand
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.aktiverModus.icon
                    size: Theme.iconSize
                    color: Theme.primary
                }

                StyledText {
                    x: parent.abstand * 2 + Theme.iconSize
                    width: parent.width - Theme.iconSize - parent.abstand * 3
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.modusLabel
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }
            }
        }
    }

    horizontalBarPill: Component {
        DankIcon {
            name: root.aktiverModus.icon
            color: Theme.widgetTextColor
            size: root.barIconPx
        }
    }

    verticalBarPill: Component {
        DankIcon {
            name: root.aktiverModus.icon
            color: Theme.widgetTextColor
            size: root.barIconPx
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Bildschirme"
            detailsText: root.modusLabel
            showCloseButton: true

            Component.onCompleted: {
                root.popoutOffen = true
                root.laden()
            }
            Component.onDestruction: root.popoutOffen = false

            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    root.popoutOffen = popout.parentPopout.shouldBeVisible
                    if (root.popoutOffen)
                        root.laden()
                }
            }

            headerActions: Component {
                DankActionButton {
                    iconName: "tune"
                    tooltipText: "Anzeigeeinstellungen"
                    onClicked: root.einstellungenOeffnen()
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingXS

                Repeater {
                    model: root.modi

                    StyledRect {
                        id: zeile

                        required property var modelData
                        readonly property bool aktiv: root.modus === zeile.modelData.id
                        readonly property bool frei: zeile.modelData.frei === true

                        width: parent.width
                        height: 48
                        radius: Theme.cornerRadius
                        color: zeile.aktiv ? Theme.surfaceContainerHigh
                             : maus.containsMouse ? Theme.surfaceContainer
                             : "transparent"
                        border.color: zeile.aktiv ? Theme.primary : "transparent"
                        border.width: zeile.aktiv ? 1 : 0
                        opacity: zeile.frei ? 1 : 0.45

                        MouseArea {
                            id: maus
                            anchors.fill: parent
                            hoverEnabled: zeile.frei
                            cursorShape: zeile.frei ? Qt.PointingHandCursor : Qt.ArrowCursor
                            enabled: zeile.frei && !zeile.aktiv
                            onClicked: root.setzen(zeile.modelData.id)
                        }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingM

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: zeile.modelData.icon
                                size: Theme.iconSize
                                color: zeile.aktiv ? Theme.primary : Theme.surfaceText
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - Theme.iconSize - haken.width - Theme.spacingM * 2
                                spacing: 0

                                StyledText {
                                    width: parent.width
                                    text: zeile.modelData.label
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    visible: text !== ""
                                    text: {
                                        if (!zeile.frei)
                                            return zeile.modelData.grund
                                        if (zeile.modelData.id === "extern" || zeile.modelData.id === "spiegeln")
                                            return root.externe.length ? root.externe[0].titel : ""
                                        return ""
                                    }
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    elide: Text.ElideRight
                                }
                            }

                            DankIcon {
                                id: haken
                                anchors.verticalCenter: parent.verticalCenter
                                name: "check"
                                size: Theme.iconSizeSmall
                                color: Theme.primary
                                visible: zeile.aktiv
                                width: visible ? Theme.iconSizeSmall : 0
                            }
                        }
                    }
                }

                // Die Anzeigeprofile von DMS -- Anordnung und Aufloesung, nicht
                // an/aus. Deshalb unter einem Trenner statt in derselben Liste.
                Rectangle {
                    visible: root.profile.length > 0
                    width: parent.width
                    height: 1
                    color: Theme.outline
                    opacity: 0.25
                }

                StyledText {
                    visible: root.profile.length > 0
                    text: "Anzeigeprofile"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    leftPadding: Theme.spacingM
                    topPadding: Theme.spacingXS
                }

                Repeater {
                    model: root.profile

                    StyledRect {
                        id: profilZeile

                        required property var modelData
                        readonly property bool aktiv: profilZeile.modelData.aktiv === true

                        width: parent.width
                        height: 40
                        radius: Theme.cornerRadius
                        color: profilMaus.containsMouse ? Theme.surfaceContainer : "transparent"

                        MouseArea {
                            id: profilMaus
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.profilSetzen(profilZeile.modelData.name)
                        }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingM

                            DankIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "bookmark"
                                size: Theme.iconSizeSmall
                                color: profilZeile.aktiv ? Theme.primary : Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: profilZeile.modelData.name
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}
