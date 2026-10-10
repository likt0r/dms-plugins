import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "Model.js" as Model

// Einstellungen des VPN-Widgets. Verbindungen werden hier nicht angelegt --
// das Popout zeigt jedes VPN-Profil, das NetworkManager kennt. Je Profil lässt
// sich nur Anzeigename, eigenes Umschaltskript und Sichtbarkeit einstellen
// (gespeichert als ein Objekt unter "connections", Schlüssel = Profilname).
PluginSettings {
    id: root
    pluginId: "vpnHub"

    Ref {
        service: DMSNetworkService
    }

    property var connections: ({})
    readonly property var rows: Model.connectionRows(DMSNetworkService.vpnProfiles, DMSNetworkService.vpnActive, root.connections, true)

    Component.onCompleted: root.connections = root.loadValue("connections", {}) || {}

    function setOverride(name, key, value) {
        const next = Object.assign({}, root.connections);
        const entry = Object.assign({}, next[name] || {});
        if (value === "" || value === false)
            delete entry[key];
        else
            entry[key] = value;
        if (Object.keys(entry).length === 0)
            delete next[name];
        else
            next[name] = entry;
        root.connections = next;
        root.saveValue("connections", next);
    }

    // --- Proton --------------------------------------------------------------

    StyledText {
        width: parent.width
        text: "Proton VPN"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "protonEnabled"
        label: "Proton VPN einbinden"
        description: "Braucht die offizielle CLI (Paket proton-vpn-cli) und einmal 'protonvpn signin <benutzer>' im Terminal. Die Proton-App darf dabei nicht laufen."
        defaultValue: true
    }

    StringSetting {
        settingKey: "protonTarget"
        label: "Standardziel"
        description: "Wohin der große Knopf und der Schalter verbinden: leer = schnellster Server, ein Ländercode wie DE oder CH, ein Server wie DE#12 oder eine Stadt wie Berlin"
        placeholder: "schnellster Server"
        defaultValue: ""
    }

    // --- Anzeige --------------------------------------------------------------

    StyledText {
        width: parent.width
        topPadding: Theme.spacingM
        text: "Anzeige"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    ToggleSetting {
        settingKey: "showLabel"
        label: "Verbindung in der Bar nennen"
        description: "Zeigt neben dem Icon, was gerade verbunden ist (bei Proton das Land)"
        defaultValue: false
    }

    // --- NetworkManager-Profile -------------------------------------------------

    StyledText {
        width: parent.width
        topPadding: Theme.spacingM
        text: "Verbindungen"
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Alle VPN-Profile aus NetworkManager. Neue Profile importierst du per Rechtsklick aufs Bar-Icon (VPN-Panel von DMS). Ein eigener Befehl wird ohne Argumente aufgerufen und entscheidet selbst, ob verbunden oder getrennt wird – absoluter Pfad, ohne Shell."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledText {
        visible: root.rows.length === 0
        width: parent.width
        text: "Keine VPN-Profile gefunden."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    Column {
        width: parent.width
        spacing: Theme.spacingS

        Repeater {
            model: root.rows

            StyledRect {
                id: card
                required property var modelData

                width: parent.width
                height: cardColumn.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh

                Column {
                    id: cardColumn
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Item {
                        width: parent.width
                        height: Math.max(Theme.iconSize, headerText.implicitHeight)

                        DankIcon {
                            id: headerIcon
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            name: card.modelData.state === "on" ? Model.ICON_ON : Model.ICON_OFF
                            size: Theme.iconSize
                            color: card.modelData.state === "on" ? Theme.primary : Theme.surfaceVariantText
                        }

                        Column {
                            id: headerText
                            anchors.left: headerIcon.right
                            anchors.leftMargin: Theme.spacingM
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            StyledText {
                                width: parent.width
                                text: card.modelData.name
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                width: parent.width
                                text: card.modelData.type + (card.modelData.state === "on" ? " · verbunden" : "")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    // Kein Wrapper: DankToggle setzt height, nicht implicitHeight.
                    DankToggle {
                        width: parent.width
                        text: "Im Popout zeigen"
                        checked: !card.modelData.hidden
                        onToggled: checked => root.setOverride(card.modelData.name, "hidden", !checked)
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: "Anzeigename"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        DankTextField {
                            width: parent.width
                            text: root.connections[card.modelData.name]?.label || ""
                            placeholderText: card.modelData.name
                            onEditingFinished: root.setOverride(card.modelData.name, "label", text.trim())
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: "Eigener Befehl zum Umschalten"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        DankTextField {
                            width: parent.width
                            text: root.connections[card.modelData.name]?.toggleCommand || ""
                            placeholderText: "leer: DMS schaltet selbst"
                            onEditingFinished: root.setOverride(card.modelData.name, "toggleCommand", text.trim())
                        }
                    }
                }
            }
        }
    }
}
