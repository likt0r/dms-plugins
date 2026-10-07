import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "warthemahl"

    ToggleSetting {
        settingKey: "vegetarianOnly"
        label: "Nur vegetarische Gerichte"
        description: "Blendet Fleisch- und Fischgerichte aus; entspricht dem Schalter im Popout und wirkt auch auf die Bar-Zeile"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showTodayInBar"
        label: "Heutiges Gericht in der Bar"
        description: "Zeigt neben dem Besteck-Icon das erste Gericht des Tages"
        defaultValue: false
    }

    SliderSetting {
        settingKey: "refreshIntervalMin"
        label: "Aktualisierungsintervall"
        description: "Wie alt der Cache sein darf, bevor neu geladen wird; Neu-laden-Knopf und Rechtsklick erzwingen den Abruf immer"
        defaultValue: 60
        minimum: 5
        maximum: 720
        unit: "min"
    }
}
