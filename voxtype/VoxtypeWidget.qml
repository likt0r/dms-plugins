import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Diktat-Status in der Bar und als OSD unten am Bildschirm. Ersatz fuer
// Omarchys Dictation.qml und fuer das von `voxtype setup dms --install`
// generierte Widget (das zielt auf ein DMS ohne Plugin-Manifest und eine
// Process-API, die es in Quickshell nicht gibt).
//
// Zwei Datenquellen, beide von voxtype selbst:
//   - Zustand: `voxtype status --follow --extended --format json`
//     (idle | recording | transcribing | streaming), als Zeilenstrom.
//   - Pegel: VoxtypePegel.qml, siehe dort -- nur waehrend der Aufnahme.
//
// Das OSD ersetzt voxtypes eigenes GTK4-Fenster; das ist in der config.toml
// per `[osd] enabled = false` abgeschaltet, sonst staenden zwei Anzeigen
// uebereinander.
PluginComponent {
    id: root

    property string dictState: "stopped"
    property string statusTooltip: "Voxtype laeuft nicht"

    // ---- Phasen ------------------------------------------------------------
    // testPhase kommt aus dem IPC-Testmodus und sticht den echten Zustand,
    // damit sich Sitz und Aussehen pruefen lassen, ohne ins Mikro zu sprechen.
    property string testPhase: ""
    readonly property bool testModus: root.testPhase !== ""
    readonly property string phase: root.testModus ? root.testPhase : root.dictState

    readonly property bool phaseAufnahme: root.phase === "recording" || root.phase === "streaming"
    readonly property bool phaseTranskribiert: root.phase === "transcribing"
    readonly property bool phaseAktiv: root.phaseAufnahme || root.phaseTranskribiert
    // Nachlauf gegen Flackern: bei kurzen Aufnahmen liegt "transcribing" auch
    // mal unter 200 ms, dann soll das OSD nicht aufblitzen und sofort gehen.
    readonly property bool osdAktiv: root.phaseAktiv || nachlauf.running

    readonly property string stateIcon: ({
        "idle": "mic",
        "recording": "fiber_manual_record",
        "streaming": "fiber_manual_record",
        "transcribing": "hourglass_top"
    })[root.phase] || "mic_off"

    // Aktiv (Aufnahme/Transkription) in der System-Akzentfarbe, sonst wie
    // die uebrigen Bar-Icons (Theme.widgetTextColor) -- kein rot/orange.
    readonly property bool isActive: root.phaseAktiv
    readonly property color stateColor: root.isActive ? Theme.primary : Theme.widgetTextColor

    // Gleiche Icon-Groesse wie die eingebauten Widgets (z.B. IdleInhibitor).
    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    // ---- Wellenform --------------------------------------------------------
    // 30 Saeulen im 100-ms-Takt = 3,0 s Fenster, also voxtypes eigenes
    // waveform_window_secs. Der Zustand liegt bewusst HIER und nicht im
    // OSD-Inhalt: DankOSD setzt seinen contentLoader auf `active: root.visible`
    // und zerstoert den Inhalt beim Verbergen -- ein Ringpuffer darin waere
    // nach jedem Ausblenden leer.
    readonly property int balken: 30
    property var pegel: new Array(30).fill(0)
    property bool stimmeAktiv: false

    // waveform_gain = 10.0 aus voxtypes config.toml. Gemessene Mikrofonpegel
    // liegen im Mittel bei 0,015 und in Spitzen bei 0,4 -- linear mal zehn
    // bringt genau das in den sichtbaren Bereich. Eine dB-Skala wuerde den
    // Rauschteppich mitheben und die Leiste auch bei Stille arbeiten lassen.
    readonly property real gain: 10.0

    function balkenHoehe(wert, maxHoehe) {
        const roh = Math.min(1, wert * root.gain)
        const eased = 1 - Math.pow(1 - roh, 3)
        return 3 + eased * (maxHoehe - 3)
    }

    function pufferLeeren() {
        root.pegel = new Array(root.balken).fill(0)
        root.stimmeAktiv = false
    }

    function schieben(wert, stimme) {
        const p = root.pegel.slice(1)
        p.push(wert)
        root.pegel = p
        root.stimmeAktiv = stimme
    }

    signal osdAnzeigen
    signal osdVerbergen

    // Was das OSD zeigt -- bleibt waehrend des Nachlaufs auf der letzten
    // aktiven Phase stehen. Ohne das blitzte nach jeder Aufnahme eine halbe
    // Sekunde lang das Leerlauf-Mikrofon mit flacher Linie auf.
    property string anzeigePhase: "idle"
    readonly property bool osdTranskribiert: root.anzeigePhase === "transcribing"
    readonly property string osdIcon: root.anzeigePhase === "transcribing"
        ? "hourglass_top" : "fiber_manual_record"

    // Hier bewusst aus root.phase neu gerechnet statt phaseAktiv/phaseAufnahme
    // zu lesen: wenn dieser Handler laeuft, koennen die abgeleiteten
    // Properties noch den alten Wert haben -- QML garantiert keine
    // Auswertungsreihenfolge zwischen Handler und Geschwister-Bindings. Genau
    // daran ist eine erste Fassung gescheitert: der Eintritt in die Aufnahme
    // landete im falschen Zweig, und am Ende wurde anzeigePhase auf "idle"
    // gesetzt statt stehenzubleiben.
    onPhaseChanged: {
        const p = root.phase
        const aufnahme = p === "recording" || p === "streaming"
        const aktiv = aufnahme || p === "transcribing"

        if (aktiv) {
            if (aufnahme && root.anzeigePhase !== p)
                root.pufferLeeren()
            root.anzeigePhase = p
            nachlauf.stop()
            root.osdAnzeigen()
        } else if (root.anzeigePhase !== "idle") {
            // Vorbei: kurz stehen lassen, damit eine sehr kurze
            // Transkriptionsphase ueberhaupt zu sehen war.
            nachlauf.restart()
        }
    }

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

    // ---- Pegelquelle und Takte ---------------------------------------------

    VoxtypePegel {
        id: pegelquelle
        aktiv: root.phaseAufnahme && !root.testModus
    }

    // Holt alle 100 ms den groessten Pegel seit dem letzten Mal. Eine
    // Zuweisung alle 100 ms statt 100 pro Sekunde -- siehe VoxtypePegel.qml.
    Timer {
        interval: 100
        repeat: true
        running: root.phaseAufnahme && !root.testModus
        onTriggered: {
            const w = pegelquelle.abholenUndLeeren()
            root.schieben(w.frames > 0 ? w.max : 0, w.stimme)
        }
    }

    // Demo-Pegel fuer `dms ipc call voxtype osd recording`: ohne Mikrofon und
    // ohne Sidecar, aber mit realistischen Groessenordnungen.
    Timer {
        interval: 100
        repeat: true
        running: root.testModus && root.phaseAufnahme
        property real zeit: 0
        onTriggered: {
            zeit += 0.1
            const huelle = 0.5 + 0.5 * Math.sin(zeit * 1.4)
            root.schieben(0.01 + Math.random() * 0.13 * huelle, huelle > 0.4)
        }
    }

    Timer {
        id: nachlauf
        interval: 500
        // anzeigePhase wird hier absichtlich NICHT zurueckgesetzt: DankOSD
        // blendet ueber ~200 ms aus, und waehrend dieser Zeit wuerde sonst
        // der Leerlauf-Inhalt (Aufnahme-Icon, flache Linie) aufblitzen. Den
        // naechsten Zustand setzt ohnehin onPhaseChanged beim naechsten
        // Diktat.
        onTriggered: root.osdVerbergen()
    }

    // Ein vergessener Testmodus soll kein Overlay stehen lassen.
    Timer {
        id: testEnde
        interval: 20000
        onTriggered: root.testPhase = ""
    }

    // Steuerung und Test von aussen:
    //   dms ipc call voxtype toggle               Aufnahme umschalten
    //   dms ipc call voxtype status               aktueller Zustand
    //   dms ipc call voxtype osd recording        OSD mit Demo-Wellenform
    //   dms ipc call voxtype osd transcribing     OSD in der Transkriptionsphase
    //   dms ipc call voxtype osd aus              Testmodus beenden
    // Bei mehreren Monitoren antwortet die zuerst registrierte Bar-Instanz;
    // nach "dms ipc call plugins reload voxtype" haengt das Target an der
    // alten Instanz (quickshell#898), dann hilft nur ein Shell-Neustart.
    IpcHandler {
        target: "voxtype"

        function toggle(): string {
            Quickshell.execDetached(["voxtype", "record", "toggle"])
            return "ok"
        }

        function status(): string {
            return root.phase + "/" + root.anzeigePhase
                + (pegelquelle.fehlt ? " (voxtype-audio-bridge fehlt)" : "")
                + (root.testModus ? " [Testmodus]" : "")
        }

        function osd(phase: string): string {
            if (phase === "aus" || phase === "off") {
                root.testPhase = ""
                testEnde.stop()
                return "ok"
            }
            if (phase !== "recording" && phase !== "transcribing")
                return "unbekannte Phase: " + phase + " (recording|transcribing|aus)"
            if (phase === "recording")
                root.pufferLeeren()
            root.testPhase = phase
            testEnde.restart()
            return "ok"
        }
    }

    Process {
        id: statusProcess
        command: ["voxtype", "status", "--follow", "--extended", "--format", "json"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    const j = JSON.parse(data)
                    // Beim Uebergang Aufnahme -> Transkription schiebt
                    // `voxtype status` eine Zeile mit leerem class-Feld und
                    // "Unknown state" dazwischen (gemessen). Die als
                    // "stopped" zu deuten liesse Bar-Icon und OSD kurz auf
                    // den Leerlauf springen -- also ueberspringen.
                    const klasse = String(j["class"] || "")
                    if (klasse === "")
                        return
                    root.dictState = klasse
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

    // ---- OSD ---------------------------------------------------------------
    // Wie in DMSShell.qml ein OSD pro Bildschirm ueber Variants. Ein einzelnes
    // DankOSD mit modelData: root.parentScreen geht nicht -- parentScreen ist
    // in Plugin-Widgets null, und ohne Screen bleibt das Fenster ohne
    // Geometrie unsichtbar.
    Variants {
        model: SettingsData.getFilteredScreens("osd")

        delegate: DankOSD {
            id: osd

            // Zwei Breiten, eine pro Phase: die Wellenform braucht Platz, die
            // Transkriptionsmeldung nicht -- sonst stuende die Karte als
            // breite Leere um eine kleine Gruppe herum. osdWidth treibt
            // implicitWidth UND die Layershell-Margins, der Wechsel verschiebt
            // das Fenster also mit. Deshalb animiert statt gesprungen.
            readonly property real breitAufnahme: Math.min(300, screenWidth - Theme.spacingM * 2)
            // Polster (2x16) + Spinner + Abstand + Text, siehe Inhalt unten.
            readonly property real breitTranskription: Math.min(
                Theme.spacingS * 4 + Theme.iconSize + Theme.spacingS * 1.5 + mass.width,
                screenWidth - Theme.spacingM * 2)

            osdWidth: root.osdTranskribiert ? breitTranskription : breitAufnahme
            osdHeight: 40 + Theme.spacingS * 2

            // Nur animieren, solange das OSD schon steht. Sonst zuppelt es
            // beim Oeffnen: anzeigePhase bleibt nach dem letzten Diktat auf
            // "transcribing" stehen, die Karte ginge also in der schmalen
            // Breite auf und wuechse erst danach auf die volle. Unsichtbar
            // wird die Breite stattdessen hart gesetzt.
            //
            // Die Pause davor: sonst quetscht sich die noch sichtbare
            // Wellenform in die schrumpfende Breite. Sie entspricht der
            // Ausblendzeit der Welle unten.
            Behavior on osdWidth {
                enabled: osd.shouldBeVisible
                SequentialAnimation {
                    PauseAnimation { duration: 110 }
                    NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
                }
            }

            TextMetrics {
                id: mass
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                font.family: Theme.fontFamily
                text: "Transkribiere…"
            }
            // Bewusst kurz: das ist das Sicherheitsnetz. Haengt der
            // Statusstrom oder stirbt das Plugin, verschwindet das OSD nach
            // 1,5 s von selbst, statt fuer immer stehenzubleiben. Offen
            // gehalten wird es vom Herzschlag unten.
            autoHideInterval: 1500
            enableMouseInteraction: false

            Connections {
                target: root
                function onOsdAnzeigen() {
                    osd.show()
                }
                function onOsdVerbergen() {
                    osd.hide()
                }
            }

            // OSDManager.showOSD verdraengt das zuvor sichtbare OSD desselben
            // Bildschirms -- eine Lautstaerkeaenderung waehrend der Aufnahme
            // wuerde unseres also wegschieben, und resetHideTimer() holt es
            // nicht zurueck (das tut bei unsichtbarem OSD gar nichts).
            // Deshalb ein Herzschlag, der kuerzer taktet als autoHideInterval
            // und fremden OSDs ihre Zeit laesst.
            Timer {
                interval: 500
                repeat: true
                running: root.osdAktiv
                onTriggered: {
                    const inhaber = OSDManager.currentOSDsByScreen[osd.screen?.name]
                    if (inhaber && inhaber !== osd && inhaber.shouldBeVisible)
                        return
                    osd.show()
                }
            }

            content: Item {
                id: inhalt

                anchors.centerIn: parent
                width: parent.width - Theme.spacingS * 2
                height: 40

                readonly property int abstand: Theme.spacingS
                readonly property real feldX: abstand + Theme.iconSize + abstand * 1.5
                readonly property real feldBreite: width - feldX - abstand

                DankIcon {
                    x: inhalt.abstand
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.osdIcon
                    size: Theme.iconSize
                    color: Theme.primary
                    opacity: root.osdTranskribiert ? 0 : 1
                    Behavior on opacity {
                        NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
                    }
                }

                // Wellenform und Text liegen dauerhaft uebereinander und
                // blenden nur um -- kein Loader, kein visible-Umschalten, sonst
                // springt es beim Phasenwechsel.
                // Kein Row mit fester Balkenbreite: die liesse rechts einen
                // Rest stehen und das Polster waere unsymmetrisch. Die
                // Saeulen teilen sich stattdessen die verfuegbare Breite auf,
                // damit links und rechts gleich viel Luft bleibt.
                Item {
                    id: welle

                    x: inhalt.feldX
                    width: inhalt.feldBreite
                    height: 28
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: root.osdTranskribiert ? 0 : 1
                    // Schneller weg als die uebrigen Ueberblendungen, damit
                    // die Karte danach ohne sichtbaren Rest schrumpfen kann.
                    Behavior on opacity {
                        NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
                    }

                    readonly property real teilung: width / root.balken
                    readonly property real luecke: 3

                    Repeater {
                        model: root.balken

                        Rectangle {
                            required property int index

                            x: index * welle.teilung
                            width: Math.max(2, welle.teilung - welle.luecke)
                            radius: width / 2
                            height: root.balkenHoehe(root.pegel[index] || 0, welle.height)
                            anchors.verticalCenter: parent.verticalCenter
                            // vad kommt ohnehin mit: faerbt die Welle nur dann
                            // in der Akzentfarbe, wenn der Daemon wirklich
                            // Sprache hoert.
                            color: root.stimmeAktiv ? Theme.primary : Theme.outline

                            Behavior on height {
                                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                            }
                            Behavior on color {
                                ColorAnimation { duration: Anims.durShort }
                            }
                        }
                    }
                }

                // Spinner und Text als eine Gruppe mittig in der Karte. Die
                // Aufnahmephase bleibt dagegen links angeschlagen, weil die
                // Wellenform die volle Breite braucht -- das Icon wandert
                // beim Phasenwechsel also bewusst in die Mitte.
                Row {
                    anchors.centerIn: parent
                    spacing: inhalt.abstand * 1.5
                    opacity: root.osdTranskribiert ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity {
                        NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
                    }

                    DankSpinner {
                        anchors.verticalCenter: parent.verticalCenter
                        size: Theme.iconSize
                        color: Theme.primary
                        running: root.osdTranskribiert
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Transkribiere…"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }
                }
            }
        }
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

                // Stand frueher auf `root.dictState === "recording" &&
                // root.surfaceLive` -- surfaceLive gibt es in DMS nicht, der
                // Ausdruck war undefined und die Animation lief nie.
                SequentialAnimation on opacity {
                    running: root.phaseAufnahme
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
                    running: root.phaseAufnahme
                    loops: Animation.Infinite
                    onStopped: pillIconV.opacity = 1
                    NumberAnimation { to: 0.4; duration: 500; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
                }
            }
        }
    }
}
