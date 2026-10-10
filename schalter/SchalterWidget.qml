import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
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
//
// Bildschirmaufnahme: Das Icon ist rot und zeigt die Laufzeit, solange
// aufgenommen wird; ein Klick (oder F10) stoppt. Sonst oeffnet er die
// Auswahl als HUD unten am Bildschirm, gebaut wie die Bildschirmauswahl auf
// F7 (Plugin bildschirme): erst der Modus (Bild, + Ton, + Mikro, + beides),
// dann ganzer Bildschirm oder Bereich. Auf F10 wandert jeder Druck eine
// Kachel weiter, nach 1,2 s ohne Druck gilt sie; per Maus wird geklickt.
// Aufgenommen wird in ~/.local/bin/bildschirmaufnahme (dotfiles-Repo,
// localbin/), das auch den Zustand fuer dieses Icon schreibt.
PluginComponent {
    id: root

    property var popoutService: null

    // Reihenfolge in der Pille. Fest, nicht nach Aktivitaet sortiert: ein
    // Icon, das seinen Platz behaelt, ist leichter zu treffen.
    // "meldungen" ersetzt DMS' notificationButton (in der Bar abgeschaltet):
    // Glocke mit rotem Punkt bei Ungelesenem, durchgestrichen bei "Nicht
    // stoeren". Klick oeffnet das Benachrichtigungszentrum unter der Glocke,
    // Mittelklick schaltet "Nicht stoeren", Rechtsklick (Pille) fuehrt ins
    // Control Center mit der Dauer-Auswahl.
    readonly property var schalter: ["wach", "vpn", "diktat", "aufnahme", "meldungen"]

    property bool gruppeGehovert: false

    // --- Anker fuer die Kachel-Plugins ---------------------------------------
    // aufnahmeKachel/diktatKachel (Control Center) zeigen nur an und reichen
    // den Klick hierher durch. Sie finden diese Instanz in
    // PluginService.globalVars, wie die Gruppe selbst vpnHub findet.
    // Gemeldet wird nur mit Schirm: das Control Center legt beim Auflisten
    // der Plugins Wegwerf-Instanzen ohne parentScreen an (WidgetModel.qml,
    // tempInstance) -- die duerfen den Eintrag nicht ueberschreiben.
    onParentScreenChanged: root.instanzMelden()
    Component.onCompleted: root.instanzMelden()
    Component.onDestruction: {
        if (PluginService.getGlobalVar("schalter", "instanz", null) === root)
            PluginService.setGlobalVar("schalter", "instanz", null)
    }

    function instanzMelden() {
        if (root.parentScreen?.name)
            PluginService.setGlobalVar("schalter", "instanz", root)
    }

    // Das VPN-Icon der gerade gebauten Pille. Nur dafuer da, dass der Weg
    // ueber IPC (und damit ein Tastenkuerzel) das Popout an derselben Stelle
    // oeffnet wie ein Mausklick. Je Schirm gibt es eine eigene Instanz dieses
    // Plugins, also zeigt es immer auf das Icon des eigenen Schirms; nur das
    // IPC-Ziel selbst haengt wie ueblich an der zuerst geladenen Instanz.
    property Item vpnIcon: null

    // Zustand des VPN-Icons kommt von vpnHub (Schild bei Proton, Schloss bei
    // anderen Tunneln, Pulsieren beim Schalten; Model.barIcon dort). Gleiche
    // Instanz wie fuer vpnPopout(); globalVars wird bei jedem Setzen neu
    // zugewiesen, die Bindung zieht also nach, sobald vpnHub geladen ist.
    readonly property var vpnHub: PluginService.getGlobalVar("vpnHub",
        "anker:" + (root.parentScreen?.name || ""), null)
    readonly property var vpnZustand: root.vpnHub?.barIcon ?? null

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

    // --- Bildschirmaufnahme ---------------------------------------------------
    // Zustandsdatei des Skripts: leer = keine Aufnahme, sonst Startzeit
    // (Epoche), Datei, PID je Zeile. FileView beobachtet nur eine Datei, die
    // beim Laden schon existiert -- fehlt sie (frischer Login), legt
    // aufnahmeDateiAnlegen sie leer an und laedt neu; danach greift der
    // Waechter auch beim Leeren und Neuschreiben.
    readonly property string aufnahmeOrdner: {
        const xdg = Quickshell.env("XDG_RUNTIME_DIR")
        return (xdg && xdg !== "" ? xdg : "/tmp") + "/bildschirmaufnahme"
    }
    readonly property string aufnahmePfad: root.aufnahmeOrdner + "/state"
    property bool aufnahmeLaeuft: false
    property real aufnahmeStart: 0
    property real jetzt: Date.now() / 1000
    property bool aufnahmeBekannt: false

    readonly property string aufnahmeDauer: {
        if (!root.aufnahmeLaeuft || root.aufnahmeStart <= 0)
            return ""
        const s = Math.max(0, Math.floor(root.jetzt - root.aufnahmeStart))
        const m = Math.floor(s / 60)
        return m + ":" + String(s % 60).padStart(2, "0")
    }

    readonly property var aufnahmeModi: [
        { id: "bild", kurz: "Bild", label: "Bild", icon: "videocam" },
        { id: "ton", kurz: "+ Ton", label: "Bild + Ton", icon: "volume_up" },
        { id: "mikro", kurz: "+ Mikro", label: "Bild + Mikro", icon: "mic" },
        { id: "beides", kurz: "+ Mikro + Ton", label: "Bild + Mikro + Ton", icon: "graphic_eq" }
    ]
    readonly property var aufnahmeBereiche: [
        { id: "schirm", kurz: "Bildschirm", icon: "desktop_windows" },
        { id: "bereich", kurz: "Bereich", icon: "crop_free" }
    ]

    // HUD: 0 = zu, 1 = Modus waehlen, 2 = Bildschirm/Bereich waehlen.
    // hudManuell: per Klick geoeffnet oder mit Pfeiltasten angefasst -- dann
    // kein Uebernahme-Timer, es gilt erst Klick bzw. Enter. Das HUD nimmt
    // Klicks an und bleibt stehen, solange der Zeiger darauf ist.
    property int hudSchritt: 0
    property bool hudManuell: false
    property int modusIndex: 0
    property int bereichIndex: 0

    signal osdZeigen
    signal osdVerbergen

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
            return root.vpnZustand ? root.vpnZustand.active : NetworkService.vpnConnected
        case "diktat":
            return root.diktatZustand === "recording"
                || root.diktatZustand === "streaming"
                || root.diktatZustand === "transcribing"
        case "aufnahme":
            return root.aufnahmeLaeuft
        case "meldungen":
            return root.ungelesen || SessionData.doNotDisturb
        }
        return false
    }

    // Eine laufende Aufnahme soll auffallen -- rot statt Akzentfarbe.
    function farbeFuer(id, aktiv) {
        if (!aktiv)
            return Theme.widgetTextColor
        return id === "aufnahme" ? Theme.error : Theme.primary
    }

    function iconFuer(id) {
        switch (id) {
        case "wach":
            return "coffee"
        case "vpn":
            return root.vpnZustand?.name || "vpn_lock"
        case "diktat":
            return root.diktatZustand === "transcribing" ? "hourglass_top" : "mic"
        case "aufnahme":
            return "screen_record"
        case "meldungen":
            return SessionData.doNotDisturb ? "notifications_off" : "notifications"
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
        case "aufnahme":
            root.aufnahmeKlick()
            break
        case "meldungen":
            root.meldungenPopout(quelle)
            break
        }
    }

    // --- Benachrichtigungen -----------------------------------------------------
    readonly property bool ungelesen: NotificationService.unreadCount > 0
    // Glocke der gerade gebauten Pille -- fuer den Weg ueber IPC, wie vpnIcon.
    property Item meldungenIcon: null

    // Das Benachrichtigungszentrum unter der Glocke aufgehen lassen. DMS'
    // eigener Knopf geht ueber DankBarContent.openWidgetPopout, das Plugins
    // nicht erreichen; der Weg hier ist derselbe wie popoutAnkern() in
    // vpn/VpnWidget.qml: Position aus getPopupTriggerPosition, dann
    // setTriggerPosition + toggle am Popout. Das Popout liegt in einem
    // LazyLoader (DMSShell.qml), active = true legt es an.
    function meldungenPopout(quelle) {
        const loader = PopoutService.notificationCenterLoader
        if (loader)
            loader.active = true
        const popout = PopoutService.notificationCenterPopout || loader?.item || null
        const ziel = quelle || root.meldungenIcon
        if (!popout || !ziel || typeof popout.setTriggerPosition !== "function") {
            PopoutService.toggleNotificationCenter()
            return
        }
        const schirm = root.parentScreen || Screen
        const kante = root.axis?.edge === "left" ? 2 : (root.axis?.edge === "right" ? 3 : (root.axis?.edge === "top" ? 0 : 1))
        const p = ziel.mapToItem(null, 0, 0)
        const pos = SettingsData.getPopupTriggerPosition({ "x": p.x, "y": p.y },
            schirm, root.barThickness, ziel.width, root.barSpacing, kante, root.barConfig)
        popout.setTriggerPosition(pos.x, pos.y, pos.width, "center", schirm, kante,
            root.barThickness, root.barSpacing, root.barConfig)
        popout.toggle()
    }

    // --- Bildschirmaufnahme: Auswahl und Steuerung ----------------------------

    function aufnahmeSkript(args) {
        Quickshell.execDetached(["sh", "-c",
            "exec \"$HOME/.local/bin/bildschirmaufnahme\" \"$@\"", "sh"].concat(args))
    }

    function aufnahmeLesen(text) {
        const zeilen = (text || "").trim().split("\n")
        const start = parseFloat(zeilen[0])
        const lief = root.aufnahmeLaeuft
        root.aufnahmeLaeuft = zeilen.length >= 3 && start > 0
        root.aufnahmeStart = root.aufnahmeLaeuft ? start : 0
        root.jetzt = Date.now() / 1000
        // Kurze Einzelanzeige beim Ende, aber nicht beim ersten Lesen nach
        // dem Shell-Start.
        if (root.aufnahmeBekannt && lief && !root.aufnahmeLaeuft) {
            root.hudSchritt = 0
            root.osdZeigen()
        }
        root.aufnahmeBekannt = true
    }

    function hudOeffnen(maus) {
        root.hudManuell = maus
        root.modusIndex = 0
        root.bereichIndex = 0
        root.hudSchritt = 1
        root.osdZeigen()
        if (maus)
            uebernahme.stop()
        else
            uebernahme.restart()
    }

    function hudSchliessen() {
        uebernahme.stop()
        root.hudSchritt = 0
        root.osdVerbergen()
    }

    // F10: laufende Aufnahme stoppen, sonst HUD oeffnen bzw. weiterwandern.
    function aufnahmeTaste() {
        if (root.aufnahmeLaeuft) {
            root.hudSchritt = 0
            root.aufnahmeSkript(["stop"])
            return
        }
        if (root.hudSchritt === 0) {
            root.hudOeffnen(false)
            return
        }
        // Wer im per Klick geoeffneten HUD zur Taste greift, bekommt ab da
        // das Tastenverhalten mit Timer.
        root.hudManuell = false
        if (root.hudSchritt === 1)
            root.modusIndex = (root.modusIndex + 1) % root.aufnahmeModi.length
        else
            root.bereichIndex = (root.bereichIndex + 1) % root.aufnahmeBereiche.length
        root.osdZeigen()
        uebernahme.restart()
    }

    function aufnahmeKlick() {
        if (root.aufnahmeLaeuft) {
            root.hudSchritt = 0
            root.aufnahmeSkript(["stop"])
            return
        }
        if (root.hudSchritt !== 0 && root.hudManuell) {
            root.hudSchliessen()
            return
        }
        root.hudOeffnen(true)
    }

    function modusWaehlen(index) {
        root.modusIndex = index
        root.bereichIndex = 0
        root.hudSchritt = 2
        root.osdZeigen()
        if (!root.hudManuell)
            uebernahme.restart()
    }

    // Tastatur im offenen HUD: Pfeile waehlen (und halten den Timer an),
    // Enter uebernimmt, Backspace geht zurueck zum Modus, Esc bricht ab.
    function hudTaste(taste) {
        if (root.hudSchritt === 0)
            return false
        const anzahl = root.hudSchritt === 2 ? root.aufnahmeBereiche.length : root.aufnahmeModi.length
        const schritt = (d) => {
            root.hudManuell = true
            uebernahme.stop()
            if (root.hudSchritt === 2)
                root.bereichIndex = (root.bereichIndex + d + anzahl) % anzahl
            else
                root.modusIndex = (root.modusIndex + d + anzahl) % anzahl
            root.osdZeigen()
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
            if (root.hudSchritt === 1)
                root.modusWaehlen(root.modusIndex)
            else
                root.aufnahmeStarten()
            return true
        case Qt.Key_Backspace:
            if (root.hudSchritt === 2) {
                uebernahme.stop()
                root.hudManuell = true
                root.hudSchritt = 1
                root.osdZeigen()
            }
            return true
        case Qt.Key_Escape:
            root.hudSchliessen()
            return true
        }
        return false
    }

    function aufnahmeStarten() {
        const modus = root.aufnahmeModi[root.modusIndex].id
        const bereich = root.aufnahmeBereiche[root.bereichIndex].id
        root.hudSchliessen()
        root.aufnahmeSkript(["start", modus, bereich])
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
        const hub = root.vpnHub
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
        id: aufnahmeDatei
        path: root.aufnahmePfad
        watchChanges: true
        printErrors: false
        onLoaded: root.aufnahmeLesen(text())
        onLoadFailed: {
            root.aufnahmeLesen("")
            if (!aufnahmeAnlegen.running)
                aufnahmeAnlegen.running = true
        }
        onFileChanged: reload()
    }

    Process {
        id: aufnahmeAnlegen
        command: ["sh", "-c", "mkdir -p \"$1\" && { [ -e \"$2\" ] || : > \"$2\"; }",
                  "sh", root.aufnahmeOrdner, root.aufnahmePfad]
        onExited: (code) => {
            if (code === 0)
                aufnahmeDatei.reload()
        }
    }

    // Laufzeit im Bar-Icon; tickt nur waehrend einer Aufnahme.
    Timer {
        interval: 1000
        repeat: true
        running: root.aufnahmeLaeuft
        onTriggered: root.jetzt = Date.now() / 1000
    }

    // Nach dieser Pause ohne weiteren Druck gilt die markierte Kachel.
    Timer {
        id: uebernahme
        interval: 1200
        onTriggered: {
            if (root.hudSchritt === 1)
                root.modusWaehlen(root.modusIndex)
            else if (root.hudSchritt === 2)
                root.aufnahmeStarten()
        }
    }

    // Beendet die Probe-Anzeige aus "osd aufnahme", ohne etwas zu starten.
    Timer {
        id: probeEnde
        interval: 8000
        onTriggered: root.hudSchliessen()
    }

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
    //                                         das vpnHub-Popout, aufnahme das
    //                                         HUD wie per Klick)
    //   dms ipc call schalter aufnahme        Taste F10: Aufnahme stoppen bzw.
    //                                         HUD oeffnen und weiterwandern
    //   dms ipc call schalter osd aufnahme    nur das HUD zeigen (8 s), zum
    //                                         Pruefen von Sitz und Aussehen
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
                return "unbekannt: " + was + " (wach|vpn|diktat|aufnahme|meldungen|alle|nichts|aus)"
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

        function aufnahme(): string {
            root.aufnahmeTaste()
            return root.aufnahmeLaeuft ? "stoppt" : "auswahl"
        }

        function osd(was: string): string {
            if (was !== "aufnahme")
                return "unbekannt: " + was + " (aufnahme)"
            root.hudOeffnen(true)
            probeEnde.restart()
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

    // --- HUD der Bildschirmaufnahme ------------------------------------------
    // Wie in DMSShell.qml (und bildschirme): ein OSD pro Bildschirm ueber
    // Variants. Ein einzelnes DankOSD mit modelData: root.parentScreen geht
    // nicht -- parentScreen ist in Plugin-Widgets null, und ohne Screen bleibt
    // das Fenster ohne Geometrie unsichtbar.
    Variants {
        model: SettingsData.getFilteredScreens("osd")

        delegate: DankOSD {
            id: osd

            readonly property real kachelBreite: 88
            readonly property real kachelHoehe: 62
            readonly property real kopfHoehe: 20
            readonly property bool auswahl: root.hudSchritt !== 0

            // Beide Schritte gleich breit, damit das HUD beim Wechsel nicht
            // springt; die zwei Bereichs-Kacheln stehen dann mittig.
            osdWidth: osd.auswahl
                ? Math.min(root.aufnahmeModi.length * kachelBreite + Theme.spacingS * 2,
                           screenWidth - Theme.spacingM * 2)
                : Math.min(Math.max(120, Theme.iconSize + beschriftung.width + Theme.spacingS * 4),
                           screenWidth - Theme.spacingM * 2)
            osdHeight: (osd.auswahl ? kopfHoehe + kachelHoehe : 40) + Theme.spacingS * 2
            // Per Klick geoeffnet: lange stehen lassen, Hover haelt es offen
            // (DankOSD.updateHoverState). Per Taste uebernimmt nach 1,2 s
            // ohnehin der Timer, die 2 s sind nur die Notbremse.
            autoHideInterval: root.hudManuell ? 8000 : 2000
            enableMouseInteraction: osd.auswahl && root.hudManuell

            // Tastaturfokus nur, solange gewaehlt wird, und nur auf dem
            // Schirm mit Fokus -- sonst stritten sich zwei exklusive Fenster
            // darum. Danach geht der Fokus ans Fenster zurueck. DankOSD selbst
            // setzt None; KeyboardFocus.keyboardFocus ist DMS' eigene Regel
            // (u. a. kein Fokus waehrend eines Screenshots).
            readonly property bool tastenFokus: osd.auswahl
                && (!NiriService.currentOutput || osd.screen?.name === NiriService.currentOutput)
            WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(osd.tastenFokus, null)

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

            // Von selbst ausgeblendet (Zeit abgelaufen): die Auswahl ist dann
            // verworfen, sonst wanderte der naechste F10-Druck in einem
            // unsichtbaren HUD weiter.
            onOsdHidden: if (root.hudSchritt !== 0 && !uebernahme.running)
                root.hudSchritt = 0

            TextMetrics {
                id: beschriftung
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                font.family: Theme.fontFamily
                text: "Aufnahme beendet"
            }

            content: Item {
                id: inhalt

                property int abstand: Theme.spacingS

                anchors.centerIn: parent
                width: parent.width - Theme.spacingS * 2
                height: parent.height - Theme.spacingS * 2

                focus: true
                Keys.onPressed: (ereignis) => {
                    if (root.hudTaste(ereignis.key))
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

                // --- Auswahl: Kopfzeile, darunter die Kacheln des Schritts
                Column {
                    anchors.centerIn: parent
                    spacing: 0
                    opacity: osd.auswahl ? 1 : 0
                    visible: opacity > 0.01
                    Behavior on opacity {
                        NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: osd.kopfHoehe
                        verticalAlignment: Text.AlignVCenter
                        text: (root.hudSchritt === 2
                            ? root.aufnahmeModi[root.modusIndex].label + " · wo?"
                            : "Bildschirmaufnahme") + "   ←→ ↵ Esc"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 0

                        Repeater {
                            model: root.hudSchritt === 2 ? root.aufnahmeBereiche : root.aufnahmeModi

                            Item {
                                id: kachel

                                required property var modelData
                                required property int index
                                readonly property bool gewaehlt: kachel.index
                                    === (root.hudSchritt === 2 ? root.bereichIndex : root.modusIndex)

                                width: osd.kachelBreite
                                height: osd.kachelHoehe

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 6
                                    height: parent.height - 4
                                    radius: Theme.cornerRadius
                                    color: kachel.gewaehlt || klick.containsMouse
                                        ? Theme.surfaceContainerHigh : "transparent"
                                    border.color: kachel.gewaehlt ? Theme.primary : "transparent"
                                    border.width: kachel.gewaehlt ? 1 : 0
                                    Behavior on color { ColorAnimation { duration: Anims.durShort } }
                                    Behavior on border.color { ColorAnimation { duration: Anims.durShort } }
                                }

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 2

                                    DankIcon {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        name: kachel.modelData.icon
                                        size: Theme.iconSize
                                        color: kachel.gewaehlt ? Theme.primary : Theme.surfaceText
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: kachel.modelData.kurz
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: kachel.gewaehlt ? Theme.primary : Theme.surfaceVariantText
                                    }
                                }

                                MouseArea {
                                    id: klick
                                    anchors.fill: parent
                                    enabled: root.hudManuell
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    // Hover meldet DankOSD, damit es nicht
                                    // unter dem Zeiger ausblendet.
                                    onContainsMouseChanged: osd.setChildHovered(containsMouse)
                                    onClicked: {
                                        if (root.hudSchritt === 1) {
                                            root.modusWaehlen(kachel.index)
                                        } else {
                                            root.bereichIndex = kachel.index
                                            root.aufnahmeStarten()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // --- Einzelanzeige, wenn eine Aufnahme endet
                Item {
                    anchors.fill: parent
                    opacity: osd.auswahl ? 0 : 1
                    visible: opacity > 0.01
                    Behavior on opacity {
                        NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
                    }

                    DankIcon {
                        x: inhalt.abstand
                        anchors.verticalCenter: parent.verticalCenter
                        name: "stop_circle"
                        size: Theme.iconSize
                        color: Theme.primary
                    }

                    StyledText {
                        x: inhalt.abstand * 2 + Theme.iconSize
                        width: parent.width - Theme.iconSize - inhalt.abstand * 3
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Aufnahme beendet"
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

                        // Die Aufnahme zeigt neben dem Icon ihre Laufzeit,
                        // der Platz waechst dann mit.
                        readonly property string zusatz: platz.modelData === "aufnahme"
                            ? root.aufnahmeDauer : ""

                        width: platz.gezeigt
                            ? root.barIconPx + (platz.zusatz !== "" ? dauer.implicitWidth + Theme.spacingXS : 0)
                            : 0
                        height: root.barIconPx
                        visible: platz.gezeigt

                        // Pulsieren auf dem Platz, nicht auf dem Icon: dessen
                        // opacity haengt schon an aktiv/inaktiv.
                        SequentialAnimation on opacity {
                            running: platz.modelData === "vpn" && (root.vpnZustand?.busy ?? false)
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) platz.opacity = 1
                            NumberAnimation { to: 0.4; duration: 600; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutQuad }
                        }

                        Component.onCompleted: {
                            if (platz.modelData === "vpn")
                                root.vpnIcon = platz
                            if (platz.modelData === "meldungen")
                                root.meldungenIcon = platz
                        }
                        Component.onDestruction: {
                            if (root.vpnIcon === platz)
                                root.vpnIcon = null
                            if (root.meldungenIcon === platz)
                                root.meldungenIcon = null
                        }

                        // Ungelesenes: roter Punkt oben rechts wie bei DMS'
                        // NotificationCenterButton.
                        Rectangle {
                            z: 1
                            width: 6
                            height: 6
                            radius: 3
                            color: Theme.error
                            x: root.barIconPx - width
                            y: 0
                            visible: platz.modelData === "meldungen" && root.ungelesen
                        }

                        StyledText {
                            id: dauer
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: platz.zusatz !== ""
                            text: platz.zusatz
                            font.pixelSize: Theme.fontSizeSmall
                            font.features: { "tnum": 1 }
                            color: Theme.error
                        }

                        DankIcon {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            name: root.iconFuer(platz.modelData)
                            filled: platz.modelData === "vpn" && (root.vpnZustand?.filled ?? false)
                            size: root.barIconPx
                            color: root.farbeFuer(platz.modelData, platz.aktiv)
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
                            acceptedButtons: platz.modelData === "meldungen"
                                ? (Qt.LeftButton | Qt.MiddleButton) : Qt.LeftButton
                            onClicked: (maus) => {
                                if (maus.button === Qt.MiddleButton)
                                    SessionData.setDoNotDisturb(!SessionData.doNotDisturb)
                                else
                                    root.schalten(platz.modelData, platz)
                            }
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

                        SequentialAnimation on opacity {
                            running: platzV.modelData === "vpn" && (root.vpnZustand?.busy ?? false)
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) platzV.opacity = 1
                            NumberAnimation { to: 0.4; duration: 600; easing.type: Easing.InOutQuad }
                            NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutQuad }
                        }

                        Component.onCompleted: if (platzV.modelData === "vpn")
                            root.vpnIcon = platzV
                        Component.onDestruction: if (root.vpnIcon === platzV)
                            root.vpnIcon = null

                        DankIcon {
                            anchors.centerIn: parent
                            name: root.iconFuer(platzV.modelData)
                            filled: platzV.modelData === "vpn" && (root.vpnZustand?.filled ?? false)
                            size: root.barIconPx
                            color: root.farbeFuer(platzV.modelData, platzV.aktiv)
                            opacity: platzV.aktiv ? 1 : 0.45
                            Behavior on opacity {
                                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: false
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: platzV.modelData === "meldungen"
                                ? (Qt.LeftButton | Qt.MiddleButton) : Qt.LeftButton
                            onClicked: (maus) => {
                                if (maus.button === Qt.MiddleButton)
                                    SessionData.setDoNotDisturb(!SessionData.doNotDisturb)
                                else
                                    root.schalten(platzV.modelData, platzV)
                            }
                        }
                    }
                }
            }
        }
    }
}
