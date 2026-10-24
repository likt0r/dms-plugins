import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// Timer mit Notiz: Nachbau von Omarchys "Reminders" (bin/omarchy-reminder,
// plugins/reminders/ReminderFlow.qml und Bar-Indikator Reminder.qml aus
// basecamp/omarchy, MIT).
//
// Wo was sitzt:
//   - Das Icon steht in der Toggle-Leiste (Plugin schalter). Sichtbar ist es,
//     solange ein Timer läuft, sonst beim Hovern. Die eigene Pille dieses
//     Plugins ist in der Bar ausgeschaltet (enabled: false), das Plugin
//     läuft aber weiter: Popout, HUD und IPC wohnen hier.
//   - Klick aufs Icon: Popout mit den laufenden Timern und "Timer
//     hinzufügen".
//   - Hinzufügen per HUD unten am Bildschirm, wie Omarchys Overlay in zwei
//     Schritten: erst die Zeit (Feld + Vorgaben, Pfeile wechseln), Enter,
//     dann die Notiz (optional), Enter. Esc bricht ab. Mod+Alt+T öffnet es
//     direkt (niri/config.kdl im dotfiles-Repo).
//
// Die Timer selbst führt systemd (bin/dms-reminder, transiente User-Timer);
// sie überleben deshalb einen Neustart der Shell.
PluginComponent {
    id: root

    property var popoutService: null

    // --- Einstellungen (Settings.qml) ---------------------------------------
    readonly property string bareUnit: Model.normalizeUnit(pluginData?.bareUnit ?? "m")
    readonly property var presetList: Model.presets(pluginData?.presets ?? "", root.bareUnit)
    readonly property bool showCountdown: pluginData?.showCountdown === true
    readonly property bool playSound: pluginData?.playSound !== false

    // --- Zustand -------------------------------------------------------------
    // Je Bildschirm gibt es eine Instanz dieses Plugins, IPC (Mod+Alt+T) und
    // das Skript erreichen aber nur die zuerst registrierte. Darum liegt die
    // Liste nicht in der Instanz, sondern geteilt in PluginService.globalVars:
    // stellt eine Instanz einen Timer, sieht die Toggle-Leiste auf jedem
    // Schirm ihn sofort, nicht erst beim Abgleich jede Minute.
    PluginGlobalVar {
        id: geteilt
        varName: "liste"
        defaultValue: []
    }
    readonly property var reminders: geteilt.value || []
    property real nowSec: Date.now() / 1000
    readonly property var next: Model.nextReminder(root.reminders, root.nowSec)
    // Was die Toggle-Leiste zeigt; liest schalter über den Anker unten.
    readonly property var leiste: Model.barState(root.reminders, root.nowSec, root.showCountdown)

    readonly property string helperPath: {
        const url = Qt.resolvedUrl("bin/dms-reminder").toString();
        return url.indexOf("file://") === 0 ? url.substring(7) : url;
    }

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    popoutWidth: 400

    Component.onCompleted: {
        root.ankerMelden();
        root.refresh();
    }

    // --- Anker für die Toggle-Leiste ------------------------------------------
    // Wie vpnHub (vpn/VpnWidget.qml, Abschnitt "Anker"): die eigene Pille ist
    // ausgeblendet, `triggerPopout()` verankerte das Popout aber an ihr. Darum
    // liegt die Instanz je Schirm in PluginService.globalVars, und schalter
    // ruft popoutAnkern() mit der Stelle des geklickten Icons.
    onParentScreenChanged: root.ankerMelden()

    function ankerMelden() {
        if (root.parentScreen?.name)
            PluginService.setGlobalVar("reminder", "anker:" + root.parentScreen.name, root);
    }

    function popoutFenster() {
        for (var i = 0; i < root.children.length; i++) {
            const kind = root.children[i];
            if (kind && typeof kind.setTriggerPosition === "function")
                return kind;
        }
        return null;
    }

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

    function popoutSchliessen() {
        const fenster = root.popoutFenster();
        if (fenster && fenster.shouldBeVisible)
            fenster.close();
    }

    // --- Fehler & Log ----------------------------------------------------------
    // Wie in vpn/ und warthemahl/: Detail ins Journal
    // (journalctl --user -u dms -g '\[reminder\]'), der kurze Grund als
    // Desktop-Benachrichtigung, kein Toast.
    function protokoll(text) {
        console.warn("[reminder] " + text);
    }

    function melden(titel, text, icon) {
        Quickshell.execDetached(["notify-send", "-a", "Timer", "-i", icon || "alarm-symbolic", titel, text || ""]);
    }

    // --- Aktionen --------------------------------------------------------------

    function refresh() {
        if (listProc.running) {
            listProc.again = true;
            return;
        }
        listProc.running = true;
    }

    function addSeconds(seconds, note) {
        const args = Model.reminderArgs(seconds, note, !root.playSound);
        if (args.length === 0)
            return false;
        addProc.command = [root.helperPath].concat(args);
        addProc.running = true;
        return true;
    }

    function cancel(unit) {
        Quickshell.execDetached([root.helperPath, "cancel", unit]);
        geteilt.set(root.reminders.filter(r => r.unit !== unit));
    }

    function clearAll() {
        Quickshell.execDetached([root.helperPath, "clear"]);
        geteilt.set([]);
    }

    // --- HUD -------------------------------------------------------------------
    // hudSchritt: 0 zu, 1 Zeit, 2 Notiz.
    property int hudSchritt: 0
    property string hudZeit: ""          // Text im Zeitfeld
    property int vorgabeIndex: -1        // gewählte Kachel, -1 = frei getippt
    property int hudSekunden: 0          // nach Schritt 1 festgehalten
    property string hudFehler: ""

    readonly property var hudVorschau: Model.preview(root.hudZeit, new Date(root.nowSec * 1000), root.bareUnit)

    signal hudZeigen
    signal hudVerbergen

    function openHud() {
        root.popoutSchliessen();
        root.nowSec = Date.now() / 1000;
        root.hudZeit = "";
        root.vorgabeIndex = -1;
        root.hudSekunden = 0;
        root.hudFehler = "";
        root.hudSchritt = 1;
        root.hudZeigen();
    }

    function hudSchliessen() {
        root.hudSchritt = 0;
        root.hudVerbergen();
    }

    function vorgabeWaehlen(index) {
        if (index < 0 || index >= root.presetList.length)
            return;
        root.vorgabeIndex = index;
        root.hudZeit = root.presetList[index].label;
        root.hudFehler = "";
    }

    // Enter in Schritt 1: Zeit prüfen und festhalten, dann die Notiz.
    function zeitUebernehmen() {
        root.nowSec = Date.now() / 1000;
        const sekunden = Model.parseDuration(root.hudZeit, new Date(), root.bareUnit);
        if (sekunden === null) {
            root.hudFehler = root.hudZeit.trim() === ""
                ? "Zeit eingeben oder mit ←/→ eine Vorgabe wählen"
                : root.hudVorschau.text;
            return;
        }
        root.hudSekunden = sekunden;
        root.hudFehler = "";
        root.hudSchritt = 2;
        root.hudZeigen();
    }

    function timerStellen(notiz) {
        if (root.hudSekunden > 0)
            root.addSeconds(root.hudSekunden, notiz);
        root.hudSchliessen();
    }

    // Tasten, die das HUD selbst behandelt; alles andere geht ins Textfeld.
    function hudTaste(ereignis, notizText) {
        switch (ereignis.key) {
        case Qt.Key_Escape:
            root.hudSchliessen();
            return true;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (root.hudSchritt === 1)
                root.zeitUebernehmen();
            else
                root.timerStellen(notizText);
            return true;
        }
        if (root.hudSchritt === 1) {
            const vor = ereignis.key === Qt.Key_Right || ereignis.key === Qt.Key_Down || ereignis.key === Qt.Key_Tab;
            const zurueck = ereignis.key === Qt.Key_Left || ereignis.key === Qt.Key_Up || ereignis.key === Qt.Key_Backtab;
            if (vor || zurueck) {
                root.vorgabeWaehlen(Model.stepIndex(root.vorgabeIndex, vor ? 1 : -1, root.presetList.length));
                return true;
            }
        } else if (ereignis.key === Qt.Key_Backspace && notizText === "") {
            // Zurück zur Zeit, wie im Aufnahme-HUD.
            root.hudSchritt = 1;
            root.hudZeigen();
            return true;
        }
        return false;
    }

    // --- IPC -------------------------------------------------------------------
    //   dms ipc call reminder openHud              Timer stellen (Mod+Alt+T)
    //   dms ipc call reminder openPopout           laufende Timer
    //   dms ipc call reminder add 25 "Tee"         ohne HUD
    //   dms ipc call reminder list | clear
    // `refresh` ruft bin/dms-reminder selbst, wenn ein Timer abgelaufen ist.
    // Antwort kommt von der zuerst registrierten Instanz.
    IpcHandler {
        target: "reminder"

        function openHud(): string {
            root.openHud();
            return "ok";
        }

        function openPopout(): string {
            root.triggerPopout();
            return "ok";
        }

        function add(spec: string, note: string): string {
            const sekunden = Model.parseDuration(spec, new Date(), root.bareUnit);
            if (sekunden === null)
                return "Unbekanntes Format: " + spec;
            root.addSeconds(sekunden, note);
            return "ok";
        }

        function list(): string {
            const jetzt = Date.now() / 1000;
            const zeilen = root.reminders.map(r => Model.title(r) + " um " + r.atTime + " (noch " + Model.describeDuration(r.at - jetzt) + ")");
            return zeilen.length ? zeilen.join("\n") : "kein Timer";
        }

        function clear(): string {
            root.clearAll();
            return "ok";
        }

        function refresh(): string {
            root.refresh();
            return "ok";
        }
    }

    // --- Prozesse --------------------------------------------------------------

    Process {
        id: listProc
        property bool again: false
        command: [root.helperPath, "show", "--json"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                const parsed = Model.parseShowJson(text);
                if (parsed)
                    geteilt.set(parsed);
            }
        }
        onExited: {
            if (again) {
                again = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    Process {
        id: addProc
        stdout: StdioCollector {
            id: addOut
            waitForEnd: true
        }
        stderr: StdioCollector {
            id: addErr
            waitForEnd: true
        }
        onExited: exitCode => {
            Qt.callLater(() => {
                // Keine Bestätigung beim Stellen (anders als Omarchy): dass
                // ein Timer läuft, zeigt das Icon in der Toggle-Leiste.
                // Gemeldet wird nur, wenn es schiefgeht.
                if (exitCode !== 0) {
                    const detail = (addErr.text + addOut.text).trim();
                    root.protokoll("dms-reminder Exit " + exitCode + ": " + detail);
                    root.melden("Timer nicht gestellt", detail.split("\n").pop() || "Exit " + exitCode, "dialog-warning");
                }
                root.refresh();
            });
        }
    }

    // Sekundentakt nur, solange etwas läuft oder das HUD offen ist.
    Timer {
        interval: 1000
        repeat: true
        running: root.next !== null || root.hudSchritt !== 0
        onTriggered: {
            const vorher = root.next;
            root.nowSec = Date.now() / 1000;
            // Abgelaufen: Liste neu holen (das Skript stößt auch an).
            if (vorher !== null && root.next === null)
                root.refresh();
        }
    }

    // Absicherung, falls ein Timer von außen gestellt oder gelöscht wurde.
    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: {
            root.nowSec = Date.now() / 1000;
            root.refresh();
        }
    }

    // --- Eigene Pille ------------------------------------------------------------
    // Nur für den Fall, dass jemand das Plugin doch direkt in die Bar setzt;
    // normal steht das Icon in der Toggle-Leiste.

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "timer"
                size: root.barIconPx
                color: root.leiste.active ? Theme.primary : Theme.widgetIconColor
            }

            StyledText {
                visible: root.leiste.text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.leiste.text
                color: Theme.primary
                font.pixelSize: Theme.fontSizeSmall
                font.features: { "tnum": 1 }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: pillIconV.width
            implicitHeight: pillIconV.height

            DIcon {
                id: pillIconV
                anchors.centerIn: parent
                name: "timer"
                size: root.barIconPx
                color: root.leiste.active ? Theme.primary : Theme.widgetIconColor
            }
        }
    }

    // --- Popout: laufende Timer ----------------------------------------------------

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Timer"
            detailsText: root.reminders.length === 0 ? "Kein Timer läuft"
                : root.reminders.length === 1 ? "1 Timer läuft"
                : root.reminders.length + " Timer laufen"
            showCloseButton: true

            Component.onCompleted: {
                root.nowSec = Date.now() / 1000;
                root.refresh();
            }
            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    if (popout.parentPopout.shouldBeVisible) {
                        root.nowSec = Date.now() / 1000;
                        root.refresh();
                    }
                }
            }

            headerActions: Component {
                DActionButton {
                    visible: root.reminders.length > 0
                    iconName: "delete_sweep"
                    tooltipText: "Alle löschen"
                    onClicked: root.clearAll()
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS
                topPadding: Theme.spacingS

                Repeater {
                    model: root.reminders

                    StyledRect {
                        id: item
                        required property var modelData
                        readonly property bool isNext: root.next !== null && root.next.unit === modelData.unit

                        width: parent.width
                        height: Math.max(52, itemText.implicitHeight + Theme.spacingM * 2)
                        radius: Theme.cornerRadius
                        color: isNext ? Theme.withAlpha(Theme.primary, 0.12) : Theme.surfaceContainerHigh

                        DIcon {
                            id: itemIcon
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            name: "timer"
                            size: Theme.iconSize
                            color: item.isNext ? Theme.primary : Theme.surfaceVariantText
                        }

                        Column {
                            id: itemText
                            anchors.left: itemIcon.right
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: countdown.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            StyledText {
                                width: parent.width
                                text: Model.title(item.modelData)
                                font.pixelSize: Theme.fontSizeMedium
                                color: item.isNext ? Theme.primary : Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                width: parent.width
                                text: "um " + item.modelData.atTime
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }

                        StyledText {
                            id: countdown
                            anchors.right: cancelButton.left
                            anchors.rightMargin: Theme.spacingXS
                            anchors.verticalCenter: parent.verticalCenter
                            text: Model.formatCountdown(item.modelData.at - root.nowSec)
                            font.pixelSize: Theme.fontSizeMedium
                            font.features: { "tnum": 1 }
                            color: item.isNext ? Theme.primary : Theme.surfaceText
                        }

                        DActionButton {
                            id: cancelButton
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            iconName: "close"
                            tooltipText: "Löschen"
                            onClicked: root.cancel(item.modelData.unit)
                        }
                    }
                }

                DButton {
                    width: parent.width
                    text: "Timer hinzufügen"
                    iconName: "add_alarm"
                    backgroundColor: Theme.primary
                    textColor: Theme.onPrimary
                    onClicked: root.openHud()
                }

                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "Mod+Alt+T"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    // --- HUD: Timer stellen --------------------------------------------------------
    // Gebaut wie das Aufnahme-HUD in schalter/SchalterWidget.qml: ein DOSD je
    // Bildschirm über Variants (in Plugins ist parentScreen null, ein einzelnes
    // OSD bliebe ohne Geometrie). Tastaturfokus nur, solange es offen ist, und
    // nur auf dem Schirm mit Fokus.
    Variants {
        model: SettingsData.getFilteredScreens("osd")

        delegate: DOSD {
            id: osd

            readonly property bool offen: root.hudSchritt !== 0
            readonly property bool tastenFokus: osd.offen
                && (!NiriService.currentOutput || osd.screen?.name === NiriService.currentOutput)
            readonly property real kachelBreite: 64
            readonly property real kachelHoehe: 34
            readonly property real kopfHoehe: 24
            readonly property real feldHoehe: 44

            osdWidth: Math.min(Math.max(360, root.presetList.length * kachelBreite + Theme.spacingS * 2) + Theme.spacingM * 2,
                               screenWidth - Theme.spacingM * 2)
            osdHeight: Theme.spacingM * 2 + kopfHoehe + Theme.spacingS + feldHoehe
                + (root.hudSchritt === 1 && root.presetList.length > 0 ? Theme.spacingS + kachelHoehe : 0)
            // Solange gewählt wird, nicht von selbst verschwinden.
            autoHideInterval: 600000
            enableMouseInteraction: osd.offen
            WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(osd.tastenFokus, null)

            Behavior on osdHeight {
                enabled: osd.shouldBeVisible
                NumberAnimation { duration: Anims.durShort; easing.type: Easing.OutCubic }
            }

            Connections {
                target: root
                function onHudZeigen() {
                    osd.show();
                }
                function onHudVerbergen() {
                    osd.hide();
                }
            }

            content: Item {
                id: inhalt

                anchors.fill: parent
                anchors.margins: Theme.spacingM

                // Fängt die Steuertasten ab, bevor das Textfeld sie sieht
                // (DTextField reicht über keyForwardTargets/Keys.forwardTo
                // zuerst hierher weiter).
                Item {
                    id: tasten
                    Keys.onPressed: ereignis => {
                        if (root.hudTaste(ereignis, notizFeld.text))
                            ereignis.accepted = true;
                    }
                }

                // Der Inhalt sitzt in einem Loader, und das OSD holt sich den
                // Fokus beim Zeigen selbst -- erst danach das Feld.
                Timer {
                    id: fokusTimer
                    interval: 120
                    onTriggered: {
                        if (root.hudSchritt === 1)
                            zeitFeld.forceActiveFocus();
                        else if (root.hudSchritt === 2)
                            notizFeld.forceActiveFocus();
                    }
                }
                Component.onCompleted: fokusTimer.restart()
                Connections {
                    target: root
                    function onHudZeigen() {
                        if (root.hudSchritt === 1)
                            zeitFeld.text = root.hudZeit;
                        else
                            notizFeld.text = "";
                        fokusTimer.restart();
                    }
                    function onHudZeitChanged() {
                        if (zeitFeld.text !== root.hudZeit)
                            zeitFeld.text = root.hudZeit;
                    }
                }

                Column {
                    anchors.fill: parent
                    spacing: Theme.spacingS

                    // Kopf: Schritt, Vorschau bzw. Fehler, Tasten.
                    Item {
                        width: parent.width
                        height: osd.kopfHoehe

                        StyledText {
                            anchors.left: parent.left
                            anchors.right: tastenHinweis.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: root.hudFehler !== "" ? Theme.error : Theme.surfaceText
                            text: {
                                if (root.hudFehler !== "")
                                    return root.hudFehler;
                                if (root.hudSchritt === 2)
                                    return "Timer " + Model.describeDuration(root.hudSekunden) + " · Notiz (optional)";
                                return root.hudVorschau.ok ? "Timer " + root.hudVorschau.text : "Timer";
                            }
                        }

                        StyledText {
                            id: tastenHinweis
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.hudSchritt === 1 ? "←→ ↵ Esc" : "↵ Esc"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    // Schritt 1: Zeit.
                    DTextField {
                        id: zeitFeld
                        visible: root.hudSchritt !== 2
                        width: parent.width
                        height: osd.feldHoehe
                        leftIconName: "timer"
                        placeholderText: root.bareUnit === "h" ? "Stunden, z. B. 2 · 3h30m4s · 14:30"
                            : root.bareUnit === "s" ? "Sekunden, z. B. 90 · 3h30m4s · 14:30"
                            : "Minuten, z. B. 25 · 3h30m4s · 14:30"
                        keyForwardTargets: [tasten]
                        onTextEdited: {
                            if (text !== root.hudZeit) {
                                root.hudZeit = text;
                                // Getippt statt gewählt: keine Kachel mehr markieren,
                                // außer der Text passt genau.
                                root.vorgabeIndex = root.presetList.findIndex(p => p.label === text);
                                root.hudFehler = "";
                            }
                        }
                    }

                    // Schritt 2: Notiz.
                    DTextField {
                        id: notizFeld
                        visible: root.hudSchritt === 2
                        width: parent.width
                        height: osd.feldHoehe
                        leftIconName: "edit_note"
                        placeholderText: "Notiz – leer lassen für einen Timer ohne Namen"
                        keyForwardTargets: [tasten]
                    }

                    // Vorgaben, nur in Schritt 1.
                    Row {
                        visible: root.hudSchritt === 1 && root.presetList.length > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 0

                        Repeater {
                            model: root.presetList

                            Item {
                                id: kachel

                                required property var modelData
                                required property int index
                                readonly property bool gewaehlt: kachel.index === root.vorgabeIndex

                                width: osd.kachelBreite
                                height: osd.kachelHoehe

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width - 6
                                    height: parent.height - 4
                                    radius: Theme.cornerRadius
                                    color: kachel.gewaehlt || klick.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                                    border.color: kachel.gewaehlt ? Theme.primary : "transparent"
                                    border.width: kachel.gewaehlt ? 1 : 0
                                    Behavior on color { ColorAnimation { duration: Anims.durShort } }
                                    Behavior on border.color { ColorAnimation { duration: Anims.durShort } }
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    text: kachel.modelData.label
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: kachel.gewaehlt ? Theme.primary : Theme.surfaceText
                                }

                                MouseArea {
                                    id: klick
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onContainsMouseChanged: osd.setChildHovered(containsMouse)
                                    onClicked: {
                                        root.vorgabeWaehlen(kachel.index);
                                        root.zeitUebernehmen();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
