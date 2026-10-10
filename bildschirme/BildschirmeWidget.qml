import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Bildschirmmodus umschalten wie GNOMEs Super+P: ein Popout mit allen Modi,
// der aktive markiert. Gedacht fuer die Anzeige-Sondertaste (ThinkPad F7,
// Keysym XF86Display), gebunden in niri/config.kdl als
//   dms ipc call bildschirme taste
// Ein Druck oeffnet das Popout, jeder weitere schaltet eine Stufe weiter --
// das Popout zeigt dabei live, wo man steht. Esc oder Klick daneben schliesst.
// Im HUD gehen auch Pfeiltasten (waehlen, halten den Timer an), Enter
// (uebernehmen) und Esc (abbrechen) -- das HUD hat dafuer, solange es offen
// ist, den Tastaturfokus. Im Popout nicht: DMS-Popouts haben keinen
// KeyCatcher.
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
    signal osdVerbergen

    readonly property string modus: root.zustand.modus || "alle"
    readonly property var externe: (root.zustand.outputs || []).filter(o => !o.intern)
    readonly property bool hatExtern: root.externe.length > 0
    readonly property bool spiegelbar: root.hatExtern && root.zustand.spiegelbar === true
    readonly property var profile: root.zustand.profile || []

    readonly property var modi: [
        {
            id: "alle",
            label: "Alle Bildschirme",
            kurz: "Alle",
            icon: "devices",
            frei: root.hatExtern,
            grund: "Nur ein Bildschirm angeschlossen"
        },
        {
            id: "extern",
            label: "Nur extern",
            kurz: "Extern",
            icon: "monitor",
            frei: root.hatExtern,
            grund: "Kein externer Bildschirm angeschlossen"
        },
        {
            id: "intern",
            label: "Nur intern",
            kurz: "Intern",
            icon: "laptop",
            frei: true,
            grund: ""
        },
        {
            id: "spiegeln",
            label: "Spiegeln",
            kurz: "Spiegeln",
            icon: "screen_share",
            frei: root.spiegelbar,
            grund: root.hatExtern ? "Braucht wl-mirror (dnf install wl-mirror)"
                                  : "Kein externer Bildschirm angeschlossen"
        }
    ]

    readonly property var aktiverModus: root.modi.find(m => m.id === root.modus) || root.modi[0]
    readonly property var freieModi: root.modi.filter(m => m.frei)

    // Auswahl im HUD, wie GNOMEs Super+P: der erste Druck zeigt alle Modi und
    // markiert den aktuellen, jeder weitere wandert eine Stufe weiter, nach
    // kurzer Pause wird uebernommen. Deshalb kein Popout mehr auf F7 -- das
    // bleibt auf dem Klick aufs Bar-Icon.
    property bool auswahlOffen: false
    // Mit Pfeiltasten angefasst: kein Uebernahme-Timer mehr, es gilt Enter.
    property bool auswahlManuell: false
    property int auswahlIndex: 0
    // Merker, damit die vom HUD selbst ausgeloeste Moduswechsel-Meldung nicht
    // direkt hinterher nochmal als Einzelanzeige aufpoppt.
    property bool ausDerAuswahl: false
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
                if (root.letzterModus !== "" && root.letzterModus !== neu.modus) {
                    if (root.ausDerAuswahl)
                        root.ausDerAuswahl = false
                    else
                        root.zeigen()
                }
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
    // Kurze Meldung im eigenen HUD statt ToastService.showWarning: der Toast
    // ist gelb (Theme.warning) und faellt aus dem Farbschema; hier steht sie
    // an derselben Stelle wie die Auswahl, Icon in Theme.primary.
    property string hinweis: ""

    function zeigen() {
        root.hinweis = ""
        root.osdZeigen()
    }

    function hinweisZeigen(text) {
        uebernahme.stop()
        root.auswahlOffen = false
        root.auswahlManuell = false
        root.hinweis = text
        root.osdZeigen()
    }

    function weiter() {
        const frei = root.modi.filter(m => m.frei)
        if (frei.length < 2) {
            root.hinweisZeigen("Kein externer Bildschirm")
            return
        }
        const i = frei.findIndex(m => m.id === root.modus)
        root.setzen(frei[(i + 1) % frei.length].id)
    }

    function tasteGedrueckt() {
        const frei = root.freieModi
        if (frei.length < 2) {
            root.hinweisZeigen("Kein externer Bildschirm")
            return
        }
        root.auswahlManuell = false
        if (!root.auswahlOffen) {
            root.auswahlOffen = true
            const i = frei.findIndex(m => m.id === root.modus)
            root.auswahlIndex = i >= 0 ? i : 0
        } else {
            root.auswahlIndex = (root.auswahlIndex + 1) % frei.length
        }
        root.zeigen()
        uebernahme.restart()
    }

    function auswahlUebernehmen() {
        const ziel = root.freieModi[root.auswahlIndex]
        root.auswahlOffen = false
        root.auswahlManuell = false
        if (ziel && ziel.id !== root.modus) {
            root.ausDerAuswahl = true
            root.setzen(ziel.id)
        }
        root.osdVerbergen()
    }

    // Tastatur im offenen HUD: Pfeile waehlen, Enter uebernimmt, Esc bricht
    // ab, ohne etwas zu schalten.
    function auswahlTaste(taste) {
        if (!root.auswahlOffen)
            return false
        const anzahl = root.freieModi.length
        const schritt = (d) => {
            root.auswahlManuell = true
            uebernahme.stop()
            probeEnde.stop()
            if (anzahl > 0)
                root.auswahlIndex = (root.auswahlIndex + d + anzahl) % anzahl
            root.zeigen()
        }
        switch (taste) {
        case Qt.Key_Left:
        case Qt.Key_Up:
        case Qt.Key_Backtab:
            schritt(-1)
            return true
        case Qt.Key_Right:
        case Qt.Key_Down:
        case Qt.Key_Tab:
            schritt(1)
            return true
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            uebernahme.stop()
            probeEnde.stop()
            root.auswahlUebernehmen()
            return true
        case Qt.Key_Escape:
            uebernahme.stop()
            probeEnde.stop()
            root.auswahlOffen = false
            root.auswahlManuell = false
            root.osdVerbergen()
            return true
        }
        return false
    }

    function einstellungenOeffnen() {
        Quickshell.execDetached(["dms", "ipc", "call", "settings", "openWith", "displays"])
    }

    pillRightClickAction: () => root.weiter()

    // Ohne zweiten Schirm gibt es nichts umzuschalten -- dann auch kein Icon.
    // F7 oeffnet das Popout ohnehin, unabhaengig von der Pille.
    onHatExternChanged: root.setVisibilityOverride(root.hatExtern)

    Component.onCompleted: {
        root.laden()
        root.setVisibilityOverride(root.hatExtern)
    }

    // Beim An- und Abstecken sofort nachlesen statt bis zum naechsten
    // 30-s-Takt zu warten. Deckt den haeufigen Fall ab; ein angeschlossener,
    // aber abgeschalteter Schirm taucht in Quickshell.screens nicht auf, den
    // faengt erst der Takt.
    Connections {
        target: Quickshell
        function onScreensChanged() {
            root.laden()
        }
    }

    // Steuerung von aussen (Keybind in niri/config.kdl):
    //   dms ipc call bildschirme taste        F7: Auswahl im HUD, weiterwandern
    //   dms ipc call bildschirme toggle       das Popout mit den Profilen
    //   dms ipc call bildschirme waehle <modus>
    //   dms ipc call bildschirme weiter
    //   dms ipc call bildschirme status
    // Bei mehreren Monitoren antwortet die zuerst registrierte Bar-Instanz;
    // nach "dms ipc call plugins reload bildschirme" haengt das Target an der
    // alten Instanz (quickshell#898), dann hilft nur ein Shell-Neustart.
    IpcHandler {
        target: "bildschirme"

        function taste(): string {
            root.tasteGedrueckt()
            return root.auswahlOffen ? "auswahl" : "nichts zu waehlen"
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
        // und Aussehen. "auswahl" zeigt die Auswahlzeile auch dann, wenn
        // mangels zweitem Schirm gar nichts zu waehlen waere.
        function osd(was: string): string {
            if (was === "auswahl") {
                root.auswahlOffen = true
                root.auswahlIndex = 0
                root.zeigen()
                probeEnde.restart()
                return "ok"
            }
            root.auswahlOffen = false
            root.zeigen()
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

    // Nach dieser Pause ohne weiteren Druck gilt die Auswahl.
    // Beendet die Probe-Auswahl, ohne etwas zu schalten.
    Timer {
        id: probeEnde
        interval: 8000
        onTriggered: {
            root.auswahlOffen = false
            root.osdVerbergen()
        }
    }

    Timer {
        id: uebernahme
        interval: 1200
        onTriggered: root.auswahlUebernehmen()
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

            readonly property real eintragBreite: 88

            osdWidth: root.auswahlOffen
                ? Math.min(root.modi.length * eintragBreite + Theme.spacingS * 2,
                           screenWidth - Theme.spacingM * 2)
                : Math.min(Math.max(120, Theme.iconSize + beschriftung.width + Theme.spacingS * 4),
                           screenWidth - Theme.spacingM * 2)
            osdHeight: (root.auswahlOffen ? 62 : 40) + Theme.spacingS * 2
            autoHideInterval: root.auswahlManuell ? 8000 : 2000
            enableMouseInteraction: false

            // Tastaturfokus nur, solange gewaehlt wird, und nur auf dem
            // Schirm mit Fokus (zwei exklusive Fenster stritten sich sonst).
            // KeyboardFocus.keyboardFocus ist DMS' eigene Regel.
            readonly property bool tastenFokus: root.auswahlOffen
                && (!NiriService.currentOutput || osd.screen?.name === NiriService.currentOutput)
            WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(osd.tastenFokus, null)

            // Von selbst ausgeblendet (8 s ohne Taste): Auswahl verwerfen,
            // sonst wanderte der naechste F7-Druck in einem unsichtbaren HUD.
            onOsdHidden: if (root.auswahlOffen && !uebernahme.running) {
                root.auswahlOffen = false
                root.auswahlManuell = false
            }

            // Nur animieren, solange das OSD schon steht -- sonst geht es beim
            // Oeffnen in der falschen Groesse auf und waechst sichtbar nach.
            Behavior on osdWidth {
                enabled: osd.shouldBeVisible
                NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
            }
            Behavior on osdHeight {
                enabled: osd.shouldBeVisible
                NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
            }

            Connections {
                target: root
                function onOsdZeigen() {
                    osd.show()
                }
                function onOsdVerbergen() {
                    osd.hide()
                }
            }

            // An den laengsten Modusnamen gehaengt, damit die Breite beim
            // Durchschalten nicht springt.
            TextMetrics {
                id: beschriftung
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                font.family: Theme.fontFamily
                text: root.hinweis !== "" ? root.hinweis : "Alle Bildschirme"
            }

            content: Item {
                id: inhalt

                property int abstand: Theme.spacingS

                anchors.centerIn: parent
                width: parent.width - Theme.spacingS * 2
                height: parent.height - Theme.spacingS * 2

                focus: true
                Keys.onPressed: (ereignis) => {
                    if (root.auswahlTaste(ereignis.key))
                        ereignis.accepted = true
                }
                // Der Inhalt sitzt in einem Loader, der den Fokus nicht von
                // selbst weitergibt -- also bei jedem Zeigen holen.
                Component.onCompleted: inhalt.forceActiveFocus()
                Connections {
                    target: root
                    function onOsdZeigen() {
                        inhalt.forceActiveFocus()
                    }
                }

                // --- Auswahl: alle Modi nebeneinander, der gewaehlte markiert
                Row {
                    anchors.centerIn: parent
                    spacing: 0
                    opacity: root.auswahlOffen ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity {
                        NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
                    }

                    Repeater {
                        model: root.modi

                        Item {
                            id: eintrag

                            required property var modelData
                            readonly property bool gewaehlt: root.auswahlOffen
                                && root.freieModi[root.auswahlIndex]
                                && root.freieModi[root.auswahlIndex].id === eintrag.modelData.id

                            width: osd.eintragBreite
                            height: 62
                            // Nicht moegliche Modi blass: sie stehen da, damit
                            // die Reihe nicht die Breite wechselt, sind aber
                            // beim Weiterwandern uebersprungen.
                            opacity: eintrag.modelData.frei ? 1 : 0.35

                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width - 6
                                height: parent.height - 4
                                radius: Theme.cornerRadius
                                color: eintrag.gewaehlt ? Theme.surfaceContainerHigh : "transparent"
                                border.color: eintrag.gewaehlt ? Theme.primary : "transparent"
                                border.width: eintrag.gewaehlt ? 1 : 0
                                Behavior on color { ColorAnimation { duration: Anims.durShort } }
                                Behavior on border.color { ColorAnimation { duration: Anims.durShort } }
                            }

                            Column {
                                anchors.centerIn: parent
                                spacing: 2

                                DankIcon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    name: eintrag.modelData.icon
                                    size: Theme.iconSize
                                    color: eintrag.gewaehlt ? Theme.primary : Theme.surfaceText
                                }

                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: eintrag.modelData.kurz
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: eintrag.gewaehlt ? Theme.primary : Theme.surfaceVariantText
                                }
                            }
                        }
                    }
                }

                // --- Einzelanzeige fuer Wechsel, die woanders ausgeloest wurden
                Item {
                    anchors.fill: parent
                    opacity: root.auswahlOffen ? 0 : 1
                    visible: opacity > 0.01
                    Behavior on opacity {
                        NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
                    }

                    DankIcon {
                        x: inhalt.abstand
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.hinweis !== "" ? "desktop_access_disabled" : root.aktiverModus.icon
                        size: Theme.iconSize
                        color: Theme.primary
                    }

                    StyledText {
                        x: inhalt.abstand * 2 + Theme.iconSize
                        width: parent.width - Theme.iconSize - inhalt.abstand * 3
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.hinweis !== "" ? root.hinweis : root.modusLabel
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }
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
