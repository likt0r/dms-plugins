import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// Ein Bar-Icon für alle VPN-Verbindungen: Port des Omarchy-Plugins likt0r.vpn,
// erweitert um Proton VPN. Aufbau und Bedienung des Popouts folgen
// proton.omarchy (48hoursnonstop/proton-vpn-omarchy, GPL-3.0) -- nur als
// Vorbild, kein Code daraus; dessen Rust-Agent gibt es nur für Arch.
//
// Woher der Zustand kommt: ausschließlich aus DMSNetworkService. Das
// DMS-Backend schiebt Änderungen, nichts wird gepollt. Auch Proton erscheint
// dort, denn die CLI legt beim Verbinden eine NM-Verbindung "ProtonVPN <Server>"
// an. Geschaltet wird je nach Art:
//   - NetworkManager-Profile über DMS (Fehler als Toast, Passwortabfrage durch
//     DMS) oder über ein eigenes Skript aus den Einstellungen,
//   - Proton über `protonvpn connect|disconnect`.
//
// Zuordnung Omarchy -> DMS: docs/omarchy-to-dms.md im dotfiles-Repo.
PluginComponent {
    id: root

    property var popoutService: null

    Ref {
        service: DMSNetworkService
    }

    // --- Einstellungen (Settings.qml) ---------------------------------------
    readonly property var overrides: pluginData?.connections || ({})
    readonly property bool showLabel: pluginData?.showLabel === true
    readonly property bool protonEnabled: pluginData?.protonEnabled !== false
    readonly property var protonDefault: Model.parseTarget(pluginData?.protonTarget || "")

    // --- Zustand --------------------------------------------------------------
    readonly property var vpnActive: DMSNetworkService.vpnActive || []
    readonly property var rows: Model.connectionRows(DMSNetworkService.vpnProfiles, root.vpnActive, root.overrides, false)
    readonly property bool anyOn: Model.anyConnected(root.vpnActive)

    property bool protonInstalled: false
    readonly property bool protonUsable: root.protonEnabled && root.protonInstalled
    readonly property var protonEntry: Model.protonActive(root.vpnActive)
    property bool protonBusy: false
    property string protonAction: ""
    readonly property string protonState: root.protonBusy ? "busy" : Model.entryState(root.protonEntry)

    property var locations: ({ countries: [], error: "", fetchedAt: 0 })
    readonly property var countries: root.locations.countries || []
    property var recents: []
    property var favorites: []

    // Was Kopf, Bar-Text und Traffic zeigen: Proton zuerst, sonst die erste
    // aktive NM-Verbindung.
    readonly property var primary: {
        if (root.protonEntry) {
            const server = Model.protonServer(root.protonEntry);
            const code = Model.serverCountry(server);
            return {
                kind: "proton",
                title: Model.countryName(root.countries, code),
                subtitle: "Proton · " + server + " · " + Model.typeLabel(root.protonEntry),
                flag: Model.countryFlag(root.countries, code),
                device: root.protonEntry.device || "",
                ip: root.protonEntry.ip || "",
                state: Model.entryState(root.protonEntry)
            };
        }
        const entry = (root.vpnActive || []).find(e => !Model.isProtonEntry(e));
        if (!entry)
            return null;
        const row = root.rows.find(r => r.name === entry.name);
        return {
            kind: "nm",
            name: entry.name,
            title: row ? row.title : entry.name,
            subtitle: Model.typeLabel(entry) + (entry.ip ? " · " + entry.ip : ""),
            flag: "",
            device: entry.device || "",
            ip: entry.ip || "",
            state: Model.entryState(entry)
        };
    }

    readonly property var barIcon: Model.barIcon({
        protonOn: root.protonState === "on" || (root.protonBusy && root.protonAction === "connect"),
        anyOn: root.anyOn,
        busy: root.protonBusy || DMSNetworkService.vpnIsBusy
    })

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    popoutWidth: 440
    // Höhe der scrollbaren Reiter; das Popout selbst hat keine Obergrenze.
    readonly property real bodyHeight: 640

    Component.onCompleted: {
        root.loadQuickTargets();
        protonCheck.running = true;
        root.ankerMelden();
    }

    onPluginServiceChanged: root.loadQuickTargets()

    // --- Anker fuer fremde Ausloeser -----------------------------------------
    // Die VPN-Taste sitzt in der schalter-Gruppe in der Bar-Mitte; die eigene
    // Pille ist ausgeblendet (settings.json: enabled false) und steht trotzdem
    // rechts in der Leiste. `triggerPopout()` verankert das Popout immer an
    // ihr -- es faehrt dann rechts herunter statt unter dem geklickten Icon.
    // Darum kann die Gruppe uns direkt ansprechen und die Stelle mitgeben.
    //
    // Der Weg dorthin ist `PluginService.globalVars`: ein Ablagefach, in dem
    // Plugins beliebige Werte unter ihrer Id hinterlegen
    // (Widgets/PluginGlobalVar.qml nutzt dasselbe). Hier liegt die Instanz
    // selbst darin, getrennt je Schirm -- sonst bediente ein Klick auf dem
    // zweiten Monitor die Instanz des ersten. Nichts davon landet auf Platte.
    //
    // Warum nicht per IPC: `dms ipc call` startet einen Prozess und erreicht
    // immer nur die zuerst registrierte Instanz, also einen festen Schirm.
    // `openPopoutAt` unten gibt es trotzdem -- zum Pruefen von Hand.
    onParentScreenChanged: root.ankerMelden()

    // Schluessel aus dem Schirm, NICHT aus einer gebundenen Property: beim
    // Melden aus onParentScreenChanged heraus steht eine solche Bindung noch
    // auf dem alten Wert, der Eintrag landete dann unter "anker:".
    function ankerSchluessel(schirm) {
        return "anker:" + (schirm?.name || "");
    }

    function ankerMelden() {
        if (root.parentScreen?.name)
            PluginService.setGlobalVar("vpnHub", root.ankerSchluessel(root.parentScreen), root);
    }

    // Das Popout gehoert PluginComponent und heisst dort `pluginPopout`; ids
    // sind dateiweit, von hier aus also unsichtbar. Es ist aber ein Kind-Item
    // und als einziges an `setTriggerPosition` zu erkennen.
    function popoutFenster() {
        for (var i = 0; i < root.children.length; i++) {
            const kind = root.children[i];
            if (kind && typeof kind.setTriggerPosition === "function")
                return kind;
        }
        return null;
    }

    // globalX/globalY/breite: wo der fremde Knopf steht. Bei waagerechter Bar
    // zaehlt nur x (das Popout wird darauf zentriert), bei senkrechter nur y.
    function popoutAnkern(globalX, globalY, breite) {
        const fenster = root.popoutFenster();
        if (!fenster) {
            root.triggerPopout();
            return;
        }
        const schirm = root.parentScreen || Screen;
        const kante = root.axis?.edge === "left" ? 2 : (root.axis?.edge === "right" ? 3 : (root.axis?.edge === "top" ? 0 : 1));
        const pos = SettingsData.getPopupTriggerPosition({
            "x": globalX,
            "y": globalY
        }, schirm, root.barThickness, breite, root.barSpacing, kante, root.barConfig);
        fenster.setTriggerPosition(pos.x, pos.y, pos.width, "center", schirm, kante, root.barThickness, root.barSpacing, root.barConfig);
        fenster.toggle();
    }

    // --- Aktionen -------------------------------------------------------------

    function toggleRow(row) {
        if (!row || row.state === "busy" || scriptProc.running)
            return;
        const isOn = row.state === "on";
        if (Model.hasCustomCommand(row)) {
            scriptProc.command = [row.toggleCommand.trim()];
            scriptProc.running = true;
            return;
        }
        const id = Model.uuidFor(DMSNetworkService.vpnProfiles, row.name);
        if (isOn)
            DMSNetworkService.disconnectVpn(id);
        else
            DMSNetworkService.connectVpn(id);
    }

    function protonConnect(target) {
        if (!root.protonUsable || protonProc.running)
            return;
        root.protonBusy = true;
        root.protonAction = "connect";
        protonProc.target = target;
        protonProc.command = Model.connectArgs(target);
        protonProc.running = true;
    }

    function protonDisconnect() {
        if (protonProc.running)
            return;
        root.protonBusy = true;
        root.protonAction = "disconnect";
        protonProc.target = null;
        protonProc.command = ["protonvpn", "disconnect"];
        protonProc.running = true;
    }

    function toggleProton() {
        if (root.protonState === "on")
            root.protonDisconnect();
        else if (root.protonState === "off")
            root.protonConnect(root.protonDefault);
    }

    // Der große Knopf im Kopf: trennt, was gerade steht, sonst verbindet er
    // Proton mit dem Standardziel.
    function heroAction() {
        if (root.primary?.kind === "proton")
            root.protonDisconnect();
        else if (root.primary?.kind === "nm")
            root.toggleRow(root.rows.find(r => r.name === root.primary.name) || { name: root.primary.name, state: "on" });
        else
            root.protonConnect(root.protonDefault);
    }

    function loadQuickTargets() {
        if (!pluginService)
            return;
        root.recents = pluginService.loadPluginState(root.pluginId, "protonRecents", []) || [];
        root.favorites = pluginService.loadPluginState(root.pluginId, "protonFavorites", []) || [];
    }

    function toggleFavorite(target) {
        root.favorites = Model.toggleFavorite(root.favorites, target);
        pluginService?.savePluginState(root.pluginId, "protonFavorites", root.favorites);
    }

    function refreshLocations(force) {
        if (!root.protonUsable || locationsProc.running)
            return;
        locationsProc.command = force ? [root.helperPath, "--force"] : [root.helperPath];
        locationsProc.running = true;
    }

    function openSettings() {
        Quickshell.execDetached(["dms", "ipc", "call", "settings", "openWith", "plugins"]);
    }

    // Rechtsklick: das VPN-Panel von DMS (Import, Details, alle Profile). Der
    // Loader ist lazy und ohne eingebautes VPN-Widget noch nie geladen.
    function openDmsVpnPanel(x, y, width, section, screen) {
        const loader = PopoutService.vpnPopoutLoader;
        if (!loader)
            return;
        loader.active = true;
        Qt.callLater(() => PopoutService.toggleVpn(x, y, width, section, screen));
    }

    pillRightClickAction: (x, y, width, section, screen) => root.openDmsVpnPanel(x, y, width, section, screen)

    readonly property string helperPath: {
        const url = Qt.resolvedUrl("bin/proton-locations").toString();
        return url.indexOf("file://") === 0 ? url.substring(7) : url;
    }

    // Steuerung von außen (Keybind in niri/config.kdl):
    //   dms ipc call vpnHub openPopout
    //   dms ipc call vpnHub openPopoutAt <x> <y> <breite>   Popout an einer
    //                                         fremden Stelle oeffnen; so
    //                                         ruft die schalter-Gruppe es,
    //                                         nur dort direkt statt per IPC
    //   dms ipc call vpnHub toggle <verbindung|proton>
    //   dms ipc call vpnHub connectTo <ziel>     Proton: "", "DE", "DE#12", "Berlin"
    //   dms ipc call vpnHub disconnectProton
    //   dms ipc call vpnHub status
    // Antwort kommt von der zuerst registrierten Instanz; nach
    // "dms ipc call plugins reload vpnHub" hängt das Target an der alten
    // (quickshell#898), dann hilft nur ein Neustart der Shell.
    IpcHandler {
        target: "vpnHub"

        function openPopout(): string {
            root.triggerPopout();
            return "ok";
        }

        function openPopoutAt(x: string, y: string, breite: string): string {
            const gx = parseFloat(x);
            const gy = parseFloat(y);
            const b = parseFloat(breite);
            if (!isFinite(gx) || !isFinite(gy) || !isFinite(b))
                return "ungueltig: x y breite in Pixeln erwartet";
            root.popoutAnkern(gx, gy, b);
            return "ok";
        }

        function toggle(connection: string): string {
            if (connection === "proton") {
                root.toggleProton();
                return "ok";
            }
            const row = Model.connectionRows(DMSNetworkService.vpnProfiles, root.vpnActive, root.overrides, true).find(r => r.name === connection || r.title === connection);
            if (!row)
                return "unbekannte Verbindung: " + connection;
            root.toggleRow(row);
            return "ok";
        }

        function connectTo(target: string): string {
            if (!root.protonUsable)
                return "Proton nicht verfügbar";
            root.protonConnect(Model.parseTarget(target));
            return "ok";
        }

        function disconnectProton(): string {
            root.protonDisconnect();
            return "ok";
        }

        function status(): string {
            const lines = (root.vpnActive || []).map(e => e.name + ": " + (Model.entryState(e) === "on" ? "verbunden" : "schaltet"));
            return lines.length ? lines.join("\n") : "keine VPN-Verbindung";
        }
    }

    // --- Prozesse -------------------------------------------------------------

    Process {
        id: protonCheck
        command: ["sh", "-c", "command -v protonvpn"]
        onExited: exitCode => {
            root.protonInstalled = exitCode === 0;
            if (root.protonInstalled)
                root.refreshLocations(false);
        }
    }

    Process {
        id: protonProc
        property var target: null
        stdout: StdioCollector {
            id: protonOut
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: protonErr
            waitForEnd: true
        }
        onExited: exitCode => {
            // Erst nach dem Auslesen freigeben: StdioCollector ist dann fertig.
            Qt.callLater(() => {
                const output = protonOut.text + "\n" + protonErr.text;
                const error = Model.cliError(output, exitCode);
                root.protonBusy = false;
                if (error !== "") {
                    ToastService.showError("Proton VPN", error);
                } else if (root.protonAction === "connect" && protonProc.target) {
                    root.recents = Model.pushRecent(root.recents, protonProc.target, 6);
                    pluginService?.savePluginState(root.pluginId, "protonRecents", root.recents);
                }
                DMSNetworkService.refreshVpnActive();
                // connect lädt eine veraltete Serverliste nach; dann auch die
                // Standorte neu zusammenfassen (der Helfer prüft das mtime).
                root.refreshLocations(false);
            });
        }
    }

    Process {
        id: scriptProc
        onExited: DMSNetworkService.refreshVpnActive()
    }

    Process {
        id: locationsProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                const parsed = Model.parseLocations(text);
                if (parsed)
                    root.locations = parsed;
            }
        }
    }

    // --- Traffic ----------------------------------------------------------------
    // Zähler des Tunnel-Interfaces, alle 2 s, solange etwas verbunden ist.
    // 150 Werte = die letzten 5 Minuten.
    //
    // Welches Interface: bei OpenVPN meldet NetworkManager als Gerät das
    // darunterliegende (wlp2s0), der Tunnel heißt tun0. Gefunden wird er über
    // die Tunnel-IP, die DMS mitliefert; ohne IP bleibt das gemeldete Gerät.
    readonly property string trafficStatsScript: "iface=$(ip -o -4 addr show | awk -v ip=\"$2\" '$4 ~ (\"^\" ip \"/\") { print $2; exit }'); "
        + "[ -n \"$iface\" ] || iface=$1; d=/sys/class/net/$iface/statistics; cat $d/rx_bytes $d/tx_bytes"

    readonly property string trafficDevice: root.primary?.state === "on" ? (root.primary.device || "") + "|" + (root.primary.ip || "") : ""
    property var rxHistory: []
    property var txHistory: []
    property real rxRate: 0
    property real txRate: 0
    property real rxTotal: 0
    property real txTotal: 0
    property bool trafficOk: false
    property var lastSample: null

    onTrafficDeviceChanged: {
        root.rxHistory = [];
        root.txHistory = [];
        root.lastSample = null;
        root.trafficOk = false;
    }

    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.trafficDevice !== ""
        onTriggered: {
            if (statsProc.running)
                return;
            const parts = root.trafficDevice.split("|");
            statsProc.command = ["sh", "-c", root.trafficStatsScript, "sh", parts[0], parts[1]];
            statsProc.running = true;
        }
    }

    Process {
        id: statsProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                const parts = text.trim().split("\n");
                if (parts.length < 2) {
                    root.trafficOk = false;
                    return;
                }
                const now = Date.now();
                const rx = Number(parts[0]);
                const tx = Number(parts[1]);
                const prev = root.lastSample;
                root.rxRate = prev ? Model.rate(prev.rx, rx, now - prev.t) : 0;
                root.txRate = prev ? Model.rate(prev.tx, tx, now - prev.t) : 0;
                root.rxTotal = rx;
                root.txTotal = tx;
                if (prev) {
                    root.rxHistory = Model.pushSample(root.rxHistory, root.rxRate, 150);
                    root.txHistory = Model.pushSample(root.txHistory, root.txRate, 150);
                }
                root.lastSample = { t: now, rx: rx, tx: tx };
                root.trafficOk = true;
            }
        }
    }

    // --- Bar ------------------------------------------------------------------

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            BarIcon {
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.showLabel && root.primary !== null
                anchors.verticalCenter: parent.verticalCenter
                text: root.primary ? root.primary.title : ""
                color: Theme.primary
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: pillIconV.width
            implicitHeight: pillIconV.height

            BarIcon {
                id: pillIconV
                anchors.centerIn: parent
            }
        }
    }

    // --- Bausteine fürs Popout ------------------------------------------------
    // Inline-Komponenten gehören ins Wurzelobjekt, in popoutContent würden sie
    // klaglos ignoriert (docs/omarchy-to-dms.md, Fallen).

    component SectionTitle: StyledText {
        width: parent ? parent.width : 0
        topPadding: Theme.spacingS
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    // Bar-Icon nach Zustand (Model.barIcon); pulsiert, solange geschaltet wird.
    component BarIcon: DankIcon {
        id: barIconItem
        name: root.barIcon.name
        filled: root.barIcon.filled
        size: root.barIconPx
        color: root.barIcon.active ? Theme.primary : Theme.widgetIconColor

        SequentialAnimation on opacity {
            running: root.barIcon.busy
            loops: Animation.Infinite
            onRunningChanged: if (!running) barIconItem.opacity = 1.0
            NumberAnimation { to: 0.4; duration: 600; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
        }
    }

    // Einfarbiges Länderkürzel statt bunter Flagge.
    component CountryBadge: StyledRect {
        id: badge
        property string code: ""
        property bool active: false
        property real pixelSize: Theme.fontSizeSmall

        implicitWidth: badgeText.implicitWidth + pixelSize * 0.9
        implicitHeight: badgeText.implicitHeight + pixelSize * 0.35
        radius: Theme.cornerRadius / 2
        color: active ? Theme.withAlpha(Theme.primary, 0.15) : Theme.surfaceContainerHighest
        border.width: 1
        border.color: active ? Theme.withAlpha(Theme.primary, 0.5) : Theme.outlineVariant

        StyledText {
            id: badgeText
            anchors.centerIn: parent
            text: Model.countryCode(badge.code)
            font.pixelSize: badge.pixelSize
            font.weight: Font.DemiBold
            font.letterSpacing: 0.5
            color: badge.active ? Theme.primary : Theme.surfaceVariantText
        }
    }

    // Eine Zeile mit Symbol oder Länderkürzel links, zwei Textzeilen und rechts
    // einem frei wählbaren Bedienelement (trailing).
    component EntryRow: StyledRect {
        id: entryRow

        property string iconName: ""
        property string flag: ""
        property string title: ""
        property string subtitle: ""
        property bool active: false
        property bool dimmed: false
        property bool clickable: false
        property Component trailing: null
        property real indent: 0
        signal clicked

        width: parent ? parent.width : 0
        height: Math.max(52, textColumn.implicitHeight + Theme.spacingM * 2)
        radius: Theme.cornerRadius
        color: entryArea.containsMouse && clickable ? Theme.surfaceContainerHighest
            : active ? Theme.withAlpha(Theme.primary, 0.12) : Theme.surfaceContainerHigh

        MouseArea {
            id: entryArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: entryRow.clickable
            cursorShape: entryRow.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: entryRow.clicked()
        }

        Item {
            id: leading
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM + entryRow.indent
            anchors.verticalCenter: parent.verticalCenter
            width: Theme.iconSize + 4
            height: Theme.iconSize + 4

            CountryBadge {
                anchors.centerIn: parent
                visible: entryRow.flag !== ""
                code: entryRow.flag
                active: entryRow.active
            }

            DankIcon {
                anchors.centerIn: parent
                visible: entryRow.flag === "" && entryRow.iconName !== ""
                name: entryRow.iconName
                size: Theme.iconSize
                color: entryRow.active ? Theme.primary : Theme.surfaceVariantText
            }
        }

        Column {
            id: textColumn
            anchors.left: leading.right
            anchors.leftMargin: Theme.spacingM
            anchors.right: trailingLoader.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            opacity: entryRow.dimmed ? 0.6 : 1.0

            StyledText {
                width: parent.width
                text: entryRow.title
                font.pixelSize: Theme.fontSizeMedium
                color: entryRow.active ? Theme.primary : Theme.surfaceText
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                visible: text !== ""
                text: entryRow.subtitle
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }

        Loader {
            id: trailingLoader
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: entryRow.trailing
        }
    }

    // --- Popout -----------------------------------------------------------------

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "VPN"
            detailsText: root.anyOn ? "Verbindung geschützt" : (root.protonBusy || DMSNetworkService.vpnIsBusy ? "Schaltet um …" : "Ungeschützt")
            showCloseButton: true

            property int tab: 0
            property string query: ""
            property int featureIndex: 0
            property string expanded: ""

            Component.onCompleted: root.refreshLocations(false)
            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    if (popout.parentPopout.shouldBeVisible) {
                        root.refreshLocations(false);
                        DMSNetworkService.refreshVpnActive();
                    }
                }
            }

            headerActions: Component {
                Row {
                    spacing: Theme.spacingXS

                    DankActionButton {
                        iconName: "settings"
                        tooltipText: "Einstellungen"
                        onClicked: {
                            if (popout.closePopout)
                                popout.closePopout();
                            root.openSettings();
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM
                topPadding: Theme.spacingS

                DankTabBar {
                    id: tabs
                    visible: root.protonUsable
                    width: parent.width
                    tabHeight: 44
                    showIcons: false
                    currentIndex: popout.tab
                    model: [({ "text": "Übersicht" }), ({ "text": "Länder" })]
                    onTabClicked: index => popout.tab = index
                    Component.onCompleted: Qt.callLater(updateIndicator)
                }

                // --- Reiter Übersicht -------------------------------------
                DankFlickable {
                    visible: popout.tab === 0 || !root.protonUsable
                    width: parent.width
                    height: Math.min(overview.implicitHeight, root.bodyHeight)
                    contentHeight: overview.implicitHeight
                    clip: true

                    Column {
                        id: overview
                        width: parent.width
                        spacing: Theme.spacingS

                        // Kopf: was gerade steht, und der große Knopf.
                        StyledRect {
                            width: parent.width
                            height: heroColumn.implicitHeight + Theme.spacingL * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Column {
                                id: heroColumn
                                anchors.fill: parent
                                anchors.margins: Theme.spacingL
                                spacing: Theme.spacingM

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    Item {
                                        width: 44
                                        height: 44
                                        anchors.verticalCenter: parent.verticalCenter

                                        CountryBadge {
                                            anchors.centerIn: parent
                                            visible: (root.primary?.flag || "") !== ""
                                            code: root.primary?.flag || ""
                                            active: root.primary?.state === "on"
                                            pixelSize: Theme.fontSizeLarge
                                        }

                                        DankIcon {
                                            anchors.centerIn: parent
                                            visible: (root.primary?.flag || "") === ""
                                            name: root.barIcon.name
                                            filled: root.barIcon.filled
                                            size: 36
                                            color: root.barIcon.active ? Theme.primary : Theme.surfaceVariantText
                                        }
                                    }

                                    Column {
                                        width: parent.width - 44 - Theme.spacingM
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2

                                        StyledText {
                                            width: parent.width
                                            text: root.primary ? root.primary.title : "Keine VPN-Verbindung"
                                            font.pixelSize: Theme.fontSizeLarge
                                            font.weight: Font.Medium
                                            color: root.primary ? Theme.primary : Theme.surfaceText
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: root.primary ? root.primary.subtitle
                                                : root.protonUsable ? "Proton: " + Model.targetLabel(root.protonDefault, root.countries).title
                                                : "Verbindung unten einschalten"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                DankButton {
                                    visible: root.primary !== null || root.protonUsable
                                    width: parent.width
                                    enabled: !root.protonBusy
                                    opacity: enabled ? 1 : 0.5
                                    text: root.protonBusy ? (root.protonAction === "connect" ? "Verbindet …" : "Trennt …")
                                        : root.primary?.kind === "proton" ? "Proton VPN trennen"
                                        : root.primary ? "Trennen"
                                        : "Proton VPN verbinden"
                                    iconName: root.primary ? "link_off" : "bolt"
                                    backgroundColor: root.primary ? Theme.surfaceContainerHighest : Theme.primary
                                    textColor: root.primary ? Theme.surfaceText : Theme.onPrimary
                                    onClicked: root.heroAction()
                                }
                            }
                        }

                        // Traffic des aktiven Tunnels.
                        StyledRect {
                            visible: root.trafficOk
                            width: parent.width
                            height: trafficColumn.implicitHeight + Theme.spacingL * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Column {
                                id: trafficColumn
                                anchors.fill: parent
                                anchors.margins: Theme.spacingL
                                spacing: Theme.spacingS

                                Row {
                                    width: parent.width

                                    Repeater {
                                        model: [
                                            { icon: "arrow_downward", label: "Download", rate: root.rxRate, total: root.rxTotal },
                                            { icon: "arrow_upward", label: "Upload", rate: root.txRate, total: root.txTotal }
                                        ]

                                        Row {
                                            required property var modelData
                                            width: trafficColumn.width / 2
                                            spacing: Theme.spacingS

                                            DankIcon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: modelData.icon
                                                size: Theme.iconSizeSmall + 2
                                                color: Theme.primary
                                            }

                                            Column {
                                                spacing: 0

                                                StyledText {
                                                    text: modelData.label
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                }
                                                StyledText {
                                                    text: Model.formatRate(modelData.rate)
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    font.weight: Font.Medium
                                                    color: Theme.surfaceText
                                                }
                                                StyledText {
                                                    text: Model.formatBytes(modelData.total)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                }
                                            }
                                        }
                                    }
                                }

                                // Download durchgezogen, Upload gestrichelt.
                                Canvas {
                                    id: graph
                                    width: parent.width
                                    height: 64

                                    readonly property real scale: Model.niceScale(Math.max.apply(null, [0].concat(root.rxHistory, root.txHistory)))
                                    property color lineColor: Theme.primary
                                    property color dashColor: Theme.surfaceVariantText
                                    property color gridColor: Theme.withAlpha(Theme.outline, 0.25)

                                    onScaleChanged: requestPaint()
                                    Connections {
                                        target: root
                                        function onRxHistoryChanged() { graph.requestPaint(); }
                                    }

                                    onPaint: {
                                        const ctx = getContext("2d");
                                        ctx.reset();
                                        ctx.strokeStyle = gridColor;
                                        ctx.lineWidth = 1;
                                        for (let i = 1; i < 4; i++) {
                                            const y = Math.round(height * i / 4) + 0.5;
                                            ctx.beginPath();
                                            ctx.moveTo(0, y);
                                            ctx.lineTo(width, y);
                                            ctx.stroke();
                                        }
                                        const draw = (values, color, dashed) => {
                                            if (values.length < 2)
                                                return;
                                            const step = width / 149;
                                            const offset = (150 - values.length) * step;
                                            ctx.strokeStyle = color;
                                            ctx.lineWidth = 2;
                                            ctx.setLineDash(dashed ? [6, 4] : []);
                                            ctx.beginPath();
                                            for (let i = 0; i < values.length; i++) {
                                                const x = offset + i * step;
                                                const y = height - 2 - Math.min(1, values[i] / scale) * (height - 4);
                                                if (i === 0)
                                                    ctx.moveTo(x, y);
                                                else
                                                    ctx.lineTo(x, y);
                                            }
                                            ctx.stroke();
                                        };
                                        draw(root.txHistory, dashColor, true);
                                        draw(root.rxHistory, lineColor, false);
                                    }
                                }

                                StyledText {
                                    text: "Letzte 5 Min. · Skala " + Model.formatRate(graph.scale)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }

                        SectionTitle {
                            text: "Verbindungen"
                        }

                        EntryRow {
                            visible: root.protonUsable
                            iconName: root.protonState === "on" ? Model.ICON_PROTON : "shield"
                            flag: root.protonEntry ? (root.primary?.flag || "") : ""
                            title: "Proton VPN"
                            subtitle: root.protonState === "busy" ? (root.protonAction === "disconnect" ? "trennt …" : "verbindet …")
                                : root.protonEntry ? Model.protonServer(root.protonEntry)
                                : Model.targetLabel(root.protonDefault, root.countries).title
                            active: root.protonState === "on"
                            trailing: Component {
                                DankToggle {
                                    checked: root.protonState === "on" || (root.protonBusy && root.protonAction === "connect")
                                    enabled: root.protonState !== "busy"
                                    opacity: enabled ? 1 : 0.5
                                    onToggled: root.toggleProton()
                                }
                            }
                        }

                        Repeater {
                            model: root.rows

                            EntryRow {
                                id: nmRow
                                required property var modelData
                                iconName: modelData.state === "on" ? Model.ICON_ON : Model.ICON_OFF
                                title: modelData.title
                                subtitle: modelData.state === "busy" ? "schaltet …"
                                    : modelData.type + (modelData.toggleCommand ? " · Skript" : "")
                                active: modelData.state === "on"
                                trailing: Component {
                                    DankToggle {
                                        checked: nmRow.modelData.state === "on"
                                        enabled: nmRow.modelData.state !== "busy" && !scriptProc.running
                                        opacity: enabled ? 1 : 0.5
                                        onToggled: root.toggleRow(nmRow.modelData)
                                    }
                                }
                            }
                        }

                        StyledText {
                            visible: root.rows.length === 0 && !root.protonUsable
                            width: parent.width
                            text: "Keine VPN-Profile in NetworkManager."
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        SectionTitle {
                            visible: quickRepeater.count > 0
                            text: "Zuletzt & Favoriten"
                        }

                        Repeater {
                            id: quickRepeater
                            model: root.protonUsable ? Model.quickTargets(root.favorites, root.recents, 6) : []

                            EntryRow {
                                id: quickRow
                                required property var modelData
                                readonly property var label: Model.targetLabel(modelData.target, root.countries)
                                iconName: "bolt"
                                flag: label.flag
                                title: label.title
                                subtitle: label.subtitle
                                clickable: !root.protonBusy
                                onClicked: root.protonConnect(modelData.target)
                                trailing: Component {
                                    Row {
                                        spacing: 0

                                        DankActionButton {
                                            iconName: "play_arrow"
                                            tooltipText: "Verbinden"
                                            enabled: !root.protonBusy
                                            onClicked: root.protonConnect(quickRow.modelData.target)
                                        }
                                        DankActionButton {
                                            iconName: "star"
                                            iconColor: quickRow.modelData.favorite ? Theme.primary : Theme.surfaceVariantText
                                            tooltipText: quickRow.modelData.favorite ? "Favorit entfernen" : "Als Favorit merken"
                                            onClicked: root.toggleFavorite(quickRow.modelData.target)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // --- Reiter Länder -----------------------------------------
                Column {
                    visible: popout.tab === 1 && root.protonUsable
                    width: parent.width
                    spacing: Theme.spacingS

                    DankTextField {
                        width: parent.width
                        leftIconName: "search"
                        placeholderText: "Land, Stadt oder Code suchen"
                        showClearButton: true
                        onTextEdited: popout.query = text
                        onTextChanged: if (text === "") popout.query = ""
                    }

                    DankFilterChips {
                        width: parent.width
                        showCounts: false
                        showCheck: false
                        chipHeight: 28
                        currentIndex: popout.featureIndex
                        model: Model.FEATURES.map(f => Model.FEATURE_LABELS[f])
                        onSelectionChanged: index => popout.featureIndex = index
                    }

                    StyledText {
                        visible: root.locations.error !== ""
                        width: parent.width
                        text: root.locations.error
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                        wrapMode: Text.WordWrap
                    }

                    ListView {
                        id: countryList
                        width: parent.width
                        height: root.bodyHeight - 110
                        clip: true
                        spacing: Theme.spacingXS
                        boundsBehavior: Flickable.StopAtBounds
                        model: Model.filterCountries(root.countries, popout.query, Model.FEATURES[popout.featureIndex])

                        delegate: Column {
                            id: countryItem
                            required property var modelData
                            readonly property string feature: Model.FEATURES[popout.featureIndex]
                            readonly property bool isOpen: popout.expanded === modelData.code
                            readonly property bool isCurrent: root.protonEntry !== null && Model.serverCountry(Model.protonServer(root.protonEntry)) === modelData.code
                            readonly property var target: ({ type: "country", country: modelData.code, feature: countryItem.feature })
                            // Städte nur ohne Secure Core: dort zählt das Eingangsland.
                            readonly property bool hasCities: feature !== "securecore" && (modelData.cities || []).length > 1

                            width: countryList.width
                            spacing: Theme.spacingXS

                            EntryRow {
                                flag: countryItem.modelData.flag
                                title: countryItem.modelData.name
                                subtitle: (countryItem.feature ? countryItem.modelData.features[countryItem.feature] : countryItem.modelData.online) + " Server · Last " + countryItem.modelData.load + " %"
                                active: countryItem.isCurrent
                                clickable: !root.protonBusy
                                onClicked: root.protonConnect(countryItem.target)
                                trailing: Component {
                                    Row {
                                        spacing: 0

                                        DankActionButton {
                                            iconName: "star"
                                            iconColor: Model.isFavorite(root.favorites, countryItem.target) ? Theme.primary : Theme.surfaceVariantText
                                            tooltipText: "Favorit"
                                            onClicked: root.toggleFavorite(countryItem.target)
                                        }
                                        DankActionButton {
                                            visible: countryItem.hasCities
                                            iconName: countryItem.isOpen ? "expand_less" : "expand_more"
                                            tooltipText: "Städte"
                                            onClicked: popout.expanded = countryItem.isOpen ? "" : countryItem.modelData.code
                                        }
                                    }
                                }
                            }

                            Repeater {
                                model: countryItem.isOpen ? countryItem.modelData.cities : []

                                EntryRow {
                                    required property var modelData
                                    indent: Theme.spacingL
                                    iconName: "location_city"
                                    title: modelData.name
                                    subtitle: modelData.servers + " Server · Last " + modelData.load + " %"
                                    clickable: !root.protonBusy
                                    onClicked: root.protonConnect({ type: "city", city: modelData.name, country: countryItem.modelData.code, feature: countryItem.feature })
                                }
                            }
                        }

                        StyledText {
                            anchors.centerIn: parent
                            visible: countryList.count === 0 && root.locations.error === ""
                            text: root.countries.length === 0 ? "Standorte werden geladen …" : "Nichts gefunden"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }
            }
        }
    }
}
