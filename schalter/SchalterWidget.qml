import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Eine Pille in der Bar-Mitte mit drei Umschaltern -- Ersatz fuer Omarchys
// `omarchy.indicators`. Aktive Umschalter sind immer zu sehen, die uebrigen
// erscheinen beim Hovern; ein Klick schaltet.
//
// DMS bringt mit `ControlCenterButton` einen aehnlichen Cluster mit, der
// idleInhibitor und doNotDisturb kennt (beide per Default aus,
// SettingsData.qml:418-419). Er reicht hier nicht: seine Gruppenliste ist fest
// einkompiliert, Plugins koennen nichts beisteuern -- das Diktat faellt also
// raus --, er klappt nicht auf, und ein Klick oeffnet das Control Center statt
// zu schalten.
//
// Inaktive Plaetze fallen ganz weg (visible: false), die Pille waechst beim
// Aufklappen. Omarchy braucht dafuer eine 120-ms-Hover-Hysterese: dort schiebt
// das Aufklappen einen Nachbarn unter den stehenden Zeiger, das klappt sofort
// wieder zu und flackert. Hier entfaellt sie, weil die Gruppe das LETZTE
// Widget der Center-Sektion ist: DMS setzt einen Anker (das mittlere Widget
// bei ungerader Zahl, sonst die beiden mittleren) und legt den Rest von dort
// nach aussen ab (CenterSection.qml:155-275). Was vor uns liegt, haengt also
// nicht von unserer Breite ab -- die linke Kante der Pille steht fest, sie
// waechst nur nach rechts, kein Nachbar bewegt sich, und der Zeiger bleibt
// drin. Wird die Gruppe spaeter NICHT ans Ende gesetzt, kommt das Problem
// zurueck und mit ihm der Bedarf an der Hysterese.
//
// Ein kleines Anfasser-Icon bleibt stehen, wenn nichts aktiv ist -- sonst
// gaebe es nichts zu hovern. Vorbild: hasNoVisibleIcons() in
// ControlCenterButton.qml:743.
PluginComponent {
    id: root

    property var popoutService: null

    // Reihenfolge in der Pille. Fest, nicht nach Aktivitaet sortiert: ein
    // Icon, das seinen Platz behaelt, ist leichter zu treffen.
    // "ruhe" (Nicht stoeren) steht bewusst NICHT hier: der notificationButton
    // rechts zeigt denselben Zustand und kann mehr -- er zaehlt ungelesene
    // Meldungen. Zwei Glocken in einer Leiste waeren eine zu viel.
    readonly property var schalter: ["wach", "vpn", "diktat"]

    property bool gruppeGehovert: false

    // Das VPN-Icon der gerade gebauten Pille. Nur dafuer da, dass der Weg
    // ueber IPC (und damit ein Tastenkuerzel) das Popout an derselben Stelle
    // oeffnet wie ein Mausklick. Je Schirm gibt es eine eigene Instanz dieses
    // Plugins, also zeigt es immer auf das Icon des eigenen Schirms; nur das
    // IPC-Ziel selbst haengt wie ueblich an der zuerst geladenen Instanz.
    property Item vpnIcon: null

    readonly property int anzahlAktiv: root.schalter.filter(id => root.istAktiv(id)).length
    readonly property bool anfasserZeigen: root.anzahlAktiv === 0 && !root.gruppeGehovert

    // Demo-Zustaende aus dem IPC, damit sich Sitz und Verhalten pruefen
    // lassen, ohne echt zu schalten.
    property var demo: []
    // Getrennt von der Liste: "nichts" muss die echten Zustaende stechen
    // koennen, sonst laesst sich der Anfasser nie pruefen, solange etwas an
    // ist.
    property bool demoLeer: false

    // --- Diktat ------------------------------------------------------------
    // Kein zweiter `voxtype status --follow`: das voxtype-Plugin haelt den
    // Strom schon fuer sein OSD. Hier reicht die Zustandsdatei per inotify.
    readonly property string zustandsPfad: {
        const xdg = Quickshell.env("XDG_RUNTIME_DIR")
        return (xdg && xdg !== "" ? xdg : "/tmp") + "/voxtype/state"
    }
    property string diktatZustand: "idle"

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    function istAktiv(id) {
        if (root.demoLeer)
            return false
        if (root.demo.indexOf(id) !== -1)
            return true
        switch (id) {
        case "wach":
            return SessionService.idleInhibited
        case "vpn":
            return NetworkService.vpnConnected
        case "diktat":
            return root.diktatZustand === "recording"
                || root.diktatZustand === "streaming"
                || root.diktatZustand === "transcribing"
        }
        return false
    }

    function iconFuer(id) {
        switch (id) {
        case "wach":
            return "coffee"
        case "vpn":
            return "vpn_lock"
        case "diktat":
            return root.diktatZustand === "transcribing" ? "hourglass_top" : "mic"
        }
        return "help"
    }

    // `quelle` ist das angeklickte Icon; nur das VPN-Popout braucht es, um
    // unter dem Icon aufzugehen statt am alten Platz der vpnHub-Pille.
    function schalten(id, quelle) {
        switch (id) {
        case "wach":
            SessionService.toggleIdleInhibit()
            break
        case "vpn":
            root.vpnPopout(quelle)
            break
        case "diktat":
            Quickshell.execDetached(["voxtype", "record", "toggle"])
            break
        }
    }

    // Nicht selbst schalten: welche der Verbindungen gemeint waere, ist nicht
    // zu erraten. Der Klick oeffnet das Popout des vpnHub-Plugins, dort stehen
    // alle Verbindungen.
    //
    // Es muss unter DIESEM Icon herunterfahren. vpnHub verankert sein Popout
    // sonst an der eigenen Pille -- die ist ausgeblendet, steht aber weiter
    // rechts in der Leiste, und das Popout faehrt dort herunter. Also reichen
    // wir die Stelle durch: vpnHub hinterlegt seine Instanz je Schirm in
    // PluginService.globalVars (siehe VpnWidget.qml, Abschnitt "Anker"), wir
    // holen sie und rufen popoutAnkern() direkt -- kein Prozessstart, und auf
    // dem zweiten Monitor trifft es die dortige Instanz.
    function vpnPopout(quelle) {
        const hub = PluginService.getGlobalVar("vpnHub",
            "anker:" + (root.parentScreen?.name || ""), null)
        const ziel = quelle || root.vpnIcon
        if (hub && ziel && typeof hub.popoutAnkern === "function") {
            const p = ziel.mapToItem(null, 0, 0)
            hub.popoutAnkern(p.x, p.y, ziel.width)
            return
        }
        // Rueckfall: vpnHub noch nicht geladen oder aelter als der Anker.
        // Dann oeffnet es sich an seinem eigenen Platz -- immer noch besser
        // als gar nichts.
        Quickshell.execDetached(["dms", "ipc", "call", "vpnHub", "openPopout"])
    }

    // Rechtsklick fuehrt ins Control Center -- dort liegen die ausfuehrlichen
    // Schalter samt Dauer fuer "Nicht stoeren".
    pillRightClickAction: () => popoutService?.toggleControlCenter()

    FileView {
        path: root.zustandsPfad
        watchChanges: true
        printErrors: false
        onLoaded: root.diktatZustand = (text() || "idle").trim()
        // Fehlende Datei ist kein Fehler: der Daemon legt sie erst an.
        onLoadFailed: root.diktatZustand = "idle"
        onFileChanged: reload()
    }

    // Steuerung und Test von aussen:
    //   dms ipc call schalter status          welche Umschalter aktiv sind
    //   dms ipc call schalter demo wach       Zustand vortaeuschen (Anzeige
    //                                         pruefen, ohne zu schalten)
    //   dms ipc call schalter demo alle|nichts|aus
    //   dms ipc call schalter toggle <id>     echt schalten (vpn oeffnet nur
    //                                         das vpnHub-Popout)
    // Nach "dms ipc call plugins reload schalter" haengt das Target an der
    // alten Instanz (quickshell#898), dann hilft nur ein Shell-Neustart.
    IpcHandler {
        target: "schalter"

        function status(): string {
            const an = root.schalter.filter(id => root.istAktiv(id))
            return an.length ? an.join(", ") : "nichts aktiv"
        }

        function demo(was: string): string {
            if (was === "aus") {
                root.demo = []
                root.demoLeer = false
                demoEnde.stop()
                return "ok"
            }
            if (was === "nichts") {
                root.demo = []
                root.demoLeer = true
                demoEnde.restart()
                return "ok"
            }
            root.demoLeer = false
            if (was === "alle") {
                root.demo = root.schalter.slice()
            } else if (root.schalter.indexOf(was) !== -1) {
                root.demo = [was]
            } else {
                return "unbekannt: " + was + " (wach|vpn|diktat|alle|nichts|aus)"
            }
            demoEnde.restart()
            return "ok"
        }

        function toggle(id: string): string {
            if (root.schalter.indexOf(id) === -1)
                return "unbekannt: " + id
            // Ohne Quelle: das VPN-Popout nimmt dann root.vpnIcon, geht
            // also an derselben Stelle auf wie beim Mausklick.
            root.schalten(id, null)
            return "ok"
        }
    }

    // Ein vergessener Demo-Zustand soll nicht dauerhaft etwas vortaeuschen.
    Timer {
        id: demoEnde
        interval: 30000
        onTriggered: {
            root.demo = []
            root.demoLeer = false
        }
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: reihe.implicitWidth
            implicitHeight: reihe.implicitHeight

            // Zuerst deklariert, liegt also unter den Klickflaechen der Icons.
            // NoButton: meldet nur Hover und schluckt keine Klicks -- die
            // gehen an die Icons darueber bzw. an die MouseArea von BasePill
            // darunter (die liegt auf z: -1).
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: root.gruppeGehovert = true
                onExited: root.gruppeGehovert = false
            }

            Row {
                id: reihe
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                // Anfasser: ohne ihn gaebe es bei nichts-aktiv keine Flaeche
                // zum Hovern, die Pille schrumpfte auf ihr blosses Polster.
                Item {
                    width: root.anfasserZeigen ? root.barIconPx : 0
                    height: root.barIconPx
                    visible: root.anfasserZeigen

                    DankIcon {
                        anchors.centerIn: parent
                        name: "more_horiz"
                        size: root.barIconPx
                        color: Theme.widgetTextColor
                        opacity: 0.45
                    }
                }

                Repeater {
                    model: root.schalter

                    Item {
                        id: platz

                        required property var modelData
                        readonly property bool aktiv: root.istAktiv(platz.modelData)

                        // Ein Kind mit visible:true und width:0 zoege im Row
                        // trotzdem sein spacing mit; nur visible:false nimmt
                        // Platz UND Abstand raus.
                        readonly property bool gezeigt: platz.aktiv || root.gruppeGehovert

                        width: platz.gezeigt ? root.barIconPx : 0
                        height: root.barIconPx
                        visible: platz.gezeigt

                        Component.onCompleted: if (platz.modelData === "vpn")
                            root.vpnIcon = platz
                        Component.onDestruction: if (root.vpnIcon === platz)
                            root.vpnIcon = null

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.iconFuer(platz.modelData)
                            size: root.barIconPx
                            color: platz.aktiv ? Theme.primary : Theme.widgetTextColor
                            // 0.45 fuer aufgedeckt-inaktiv ist aus Omarchys
                            // Indicators uebernommen -- sichtbar genug zum
                            // Treffen, leise genug, um nicht nach Zustand
                            // auszusehen.
                            opacity: platz.aktiv ? 1 : 0.45
                            Behavior on opacity {
                                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                            }
                        }

                        // hoverEnabled bewusst aus: sonst zoege diese Flaeche
                        // den Hover von der Gruppenflaeche darunter ab und die
                        // aufgedeckten Icons flackerten beim Darueberfahren.
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: false
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.schalten(platz.modelData, platz)
                        }
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: spalte.implicitWidth
            implicitHeight: spalte.implicitHeight

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: root.gruppeGehovert = true
                onExited: root.gruppeGehovert = false
            }

            Column {
                id: spalte
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                // Anfasser: ohne ihn gaebe es bei nichts-aktiv keine Flaeche
                // zum Hovern, die Pille schrumpfte auf ihr blosses Polster.
                Item {
                    width: root.anfasserZeigen ? root.barIconPx : 0
                    height: root.barIconPx
                    visible: root.anfasserZeigen

                    DankIcon {
                        anchors.centerIn: parent
                        name: "more_horiz"
                        size: root.barIconPx
                        color: Theme.widgetTextColor
                        opacity: 0.45
                    }
                }

                Item {
                    width: root.barIconPx
                    height: root.anfasserZeigen ? root.barIconPx : 0
                    visible: root.anfasserZeigen

                    DankIcon {
                        anchors.centerIn: parent
                        name: "more_horiz"
                        size: root.barIconPx
                        color: Theme.widgetTextColor
                        opacity: 0.45
                    }
                }

                Repeater {
                    model: root.schalter

                    Item {
                        id: platzV

                        required property var modelData
                        readonly property bool aktiv: root.istAktiv(platzV.modelData)

                        readonly property bool gezeigt: platzV.aktiv || root.gruppeGehovert

                        width: root.barIconPx
                        height: platzV.gezeigt ? root.barIconPx : 0
                        visible: platzV.gezeigt

                        Component.onCompleted: if (platzV.modelData === "vpn")
                            root.vpnIcon = platzV
                        Component.onDestruction: if (root.vpnIcon === platzV)
                            root.vpnIcon = null

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.iconFuer(platzV.modelData)
                            size: root.barIconPx
                            color: platzV.aktiv ? Theme.primary : Theme.widgetTextColor
                            opacity: platzV.aktiv ? 1 : 0.45
                            Behavior on opacity {
                                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: false
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.schalten(platzV.modelData, platzV)
                        }
                    }
                }
            }
        }
    }
}
