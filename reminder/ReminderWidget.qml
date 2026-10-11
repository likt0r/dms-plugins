import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// Erinnerungen mit Countdown: Nachbau von Omarchys "Reminders"
// (bin/omarchy-reminder, plugins/reminders/ReminderFlow.qml und dem
// Bar-Indikator Reminder.qml aus basecamp/omarchy, MIT).
//
// Die Timer selbst führt systemd (bin/dms-reminder, transiente User-Timer).
// Das Widget stellt sie nur, listet sie und zählt herunter -- deshalb gehen
// Erinnerungen bei einem Neustart der Shell nicht verloren.
//
// Statt Omarchys Vollbild-Overlay mit zwei Schritten (erst Minuten, dann
// Nachricht) hat das Popout beide Felder untereinander: Enter im ersten
// springt ins zweite, Enter im zweiten stellt die Erinnerung.
PluginComponent {
    id: root

    property var popoutService: null

    readonly property bool showCountdown: pluginData?.showCountdown !== false
    readonly property bool playSound: pluginData?.playSound !== false
    readonly property var quickTimes: Model.quickTimes(pluginData?.quickTimes ?? "")

    property var reminders: []
    property real nowSec: Date.now() / 1000
    readonly property var next: Model.nextReminder(root.reminders, root.nowSec)
    readonly property bool active: root.next !== null

    readonly property string helperPath: {
        const url = Qt.resolvedUrl("bin/dms-reminder").toString();
        return url.indexOf("file://") === 0 ? url.substring(7) : url;
    }

    readonly property real barIconPx: Theme.barIconSize(root.barThickness, -4,
        root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)

    popoutWidth: 420

    Component.onCompleted: root.refresh()

    function refresh() {
        if (listProc.running) {
            listProc.again = true;
            return;
        }
        listProc.running = true;
    }

    // Wie in vpn/ und warthemahl/: Detail per console.warn ins Log, der kurze
    // Grund als Desktop-Benachrichtigung (kein Toast). Nicht transient, damit
    // sie im Benachrichtigungszentrum bleibt.
    function protokoll(text) {
        console.warn("[reminder] " + text);
    }

    function melden(titel, text, icon) {
        Quickshell.execDetached(["notify-send", "-a", "Erinnerung", "-i", icon || "alarm-symbolic", titel, text || ""]);
    }

    // Gibt "" zurück oder eine Fehlermeldung für die Vorschau.
    function add(spec, message) {
        const seconds = Model.parseDuration(spec, new Date());
        if (seconds === null)
            return "Unbekanntes Format: " + spec;
        const args = Model.reminderArgs(seconds, message, !root.playSound);
        addProc.summary = (String(message || "").trim() || "Erinnerung") + " in " + Model.describeDuration(seconds);
        addProc.command = [root.helperPath].concat(args);
        addProc.running = true;
        return "";
    }

    function cancel(unit) {
        Quickshell.execDetached([root.helperPath, "cancel", unit]);
        root.reminders = root.reminders.filter(r => r.unit !== unit);
    }

    function clearAll() {
        Quickshell.execDetached([root.helperPath, "clear"]);
        root.reminders = [];
    }

    // Steuerung von außen (Keybind in niri/config.kdl):
    //   dms ipc call reminder openPopout
    //   dms ipc call reminder add 15 "Tee ist fertig"
    //   dms ipc call reminder list | clear
    // `refresh` ruft bin/dms-reminder selbst, wenn eine Erinnerung fällig war.
    IpcHandler {
        target: "reminder"

        function openPopout(): string {
            root.triggerPopout();
            return "ok";
        }

        function add(spec: string, message: string): string {
            return root.add(spec, message) || "ok";
        }

        function list(): string {
            const lines = root.reminders.map(r => Model.label(r) + " um " + r.atTime + " (noch " + Model.describeDuration(r.at - Date.now() / 1000) + ")");
            return lines.length ? lines.join("\n") : "keine Erinnerungen";
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

    Process {
        id: listProc
        property bool again: false
        command: [root.helperPath, "show", "--json"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                const parsed = Model.parseShowJson(text);
                if (parsed)
                    root.reminders = parsed;
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
        property string summary: ""
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
                if (exitCode === 0) {
                    // Ausgabe: "<unit> <HH:MM>" -- Bestätigung wie bei Omarchy.
                    const at = addOut.text.trim().split(" ").pop();
                    root.melden(addProc.summary, "um " + at);
                } else {
                    const detail = (addErr.text + addOut.text).trim();
                    root.protokoll("dms-reminder Exit " + exitCode + ": " + detail);
                    root.melden("Erinnerung nicht gestellt", detail.split("\n").pop() || "Exit " + exitCode, "dialog-warning");
                }
                root.refresh();
            });
        }
    }

    // Sekundentakt nur, solange etwas läuft.
    Timer {
        interval: 1000
        repeat: true
        running: root.active
        onTriggered: {
            root.nowSec = Date.now() / 1000;
            // Fällig geworden: Liste neu holen (das Skript stößt auch an).
            if (root.next === null)
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

    // --- Bar ------------------------------------------------------------------

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.active ? "alarm_on" : "alarm"
                size: root.barIconPx
                color: root.active ? Theme.primary : Theme.widgetIconColor
            }

            StyledText {
                visible: root.active && root.showCountdown
                anchors.verticalCenter: parent.verticalCenter
                text: root.next ? Model.formatCountdown(root.next.at - root.nowSec) : ""
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

            DankIcon {
                id: pillIconV
                anchors.centerIn: parent
                name: root.active ? "alarm_on" : "alarm"
                size: root.barIconPx
                color: root.active ? Theme.primary : Theme.widgetIconColor
            }
        }
    }

    // --- Popout -----------------------------------------------------------------

    component FieldLabel: StyledText {
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "Erinnerung"
            detailsText: root.reminders.length === 0 ? "Nichts geplant"
                : root.reminders.length === 1 ? "1 Erinnerung läuft"
                : root.reminders.length + " Erinnerungen laufen"
            showCloseButton: true

            property string error: ""
            readonly property var hint: Model.preview(whenField.text, new Date(root.nowSec * 1000))

            function focusFirst() {
                whenField.text = "";
                messageField.text = "";
                popout.error = "";
                focusTimer.restart();
            }

            // PluginPopout zieht den Fokus beim Öffnen per Qt.callLater auf
            // seinen Container (für Esc). Erst danach das Zeitfeld fokussieren,
            // sonst landet die Eingabe im Leeren.
            Timer {
                id: focusTimer
                interval: 120
                onTriggered: whenField.forceActiveFocus()
            }

            function submit() {
                if (!popout.hint.ok) {
                    popout.error = popout.hint.text || "Wann soll erinnert werden?";
                    whenField.forceActiveFocus();
                    return;
                }
                const error = root.add(whenField.text, messageField.text);
                if (error !== "") {
                    popout.error = error;
                    return;
                }
                if (popout.closePopout)
                    popout.closePopout();
            }

            Component.onCompleted: {
                root.nowSec = Date.now() / 1000;
                root.refresh();
                popout.focusFirst();
            }
            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    if (popout.parentPopout.shouldBeVisible) {
                        root.nowSec = Date.now() / 1000;
                        root.refresh();
                        popout.focusFirst();
                    }
                }
            }

            headerActions: Component {
                DankActionButton {
                    visible: root.reminders.length > 0
                    iconName: "delete_sweep"
                    tooltipText: "Alle löschen"
                    onClicked: root.clearAll()
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM
                topPadding: Theme.spacingS

                // --- Neue Erinnerung --------------------------------------
                StyledRect {
                    width: parent.width
                    height: form.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: form
                        anchors.fill: parent
                        anchors.margins: Theme.spacingL
                        spacing: Theme.spacingM

                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS

                            FieldLabel {
                                text: "Wann?"
                            }

                            DankTextField {
                                id: whenField
                                width: parent.width
                                leftIconName: "schedule"
                                placeholderText: "15 · 1h30 · 45s · 14:30"
                                onTextEdited: popout.error = ""
                                onAccepted: {
                                    if (popout.hint.ok)
                                        messageField.forceActiveFocus();
                                    else
                                        popout.submit();
                                }
                            }

                            StyledText {
                                width: parent.width
                                visible: text !== ""
                                text: popout.error !== "" ? popout.error : popout.hint.text
                                font.pixelSize: Theme.fontSizeSmall
                                color: popout.error !== "" || (!popout.hint.ok && popout.hint.text !== "") ? Theme.error : Theme.primary
                                wrapMode: Text.WordWrap
                            }
                        }

                        // Schnellwahl füllt nur das Zeitfeld.
                        Flow {
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: root.quickTimes

                                DankButton {
                                    required property var modelData
                                    text: Model.quickLabel(modelData)
                                    buttonHeight: 30
                                    horizontalPadding: Theme.spacingM
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                    onClicked: {
                                        whenField.text = String(modelData);
                                        popout.error = "";
                                        messageField.forceActiveFocus();
                                    }
                                }
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingXS

                            FieldLabel {
                                text: "Woran erinnern?"
                            }

                            DankTextField {
                                id: messageField
                                width: parent.width
                                leftIconName: "edit_note"
                                placeholderText: "z. B. Tee ist fertig"
                                onAccepted: popout.submit()
                            }
                        }

                        DankButton {
                            width: parent.width
                            text: "Erinnern"
                            iconName: "alarm_add"
                            enabled: popout.hint.ok && !addProc.running
                            opacity: enabled ? 1 : 0.5
                            backgroundColor: Theme.primary
                            textColor: Theme.onPrimary
                            onClicked: popout.submit()
                        }
                    }
                }

                // --- Laufende Erinnerungen ----------------------------------
                StyledText {
                    visible: root.reminders.length > 0
                    width: parent.width
                    topPadding: Theme.spacingXS
                    text: "Laufend"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }

                Column {
                    visible: root.reminders.length > 0
                    width: parent.width
                    spacing: Theme.spacingS

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

                            DankIcon {
                                id: itemIcon
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter
                                name: "alarm"
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
                                    text: Model.label(item.modelData)
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

                            DankActionButton {
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
                }
            }
        }
    }
}
