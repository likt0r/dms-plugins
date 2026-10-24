import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "schalter"

    SelectionSetting {
        settingKey: "hoverSeite"
        label: "Inaktive Schalter beim Hovern"
        description: "Wohin die übrigen Icons aufklappen. Die aktiven bleiben dabei stehen, nichts rutscht unter dem Mauszeiger weg. Bei senkrechter Leiste heißt rechts unten und links oben"
        options: [
            { label: "Rechts daneben", value: "rechts" },
            { label: "Links daneben", value: "links" }
        ]
        defaultValue: "rechts"
    }
}
