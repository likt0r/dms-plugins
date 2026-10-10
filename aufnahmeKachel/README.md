# Bildschirmaufnahme (Kachel)

Kachel im Control Center fuer die Bildschirmaufnahme der
[`schalter`](../schalter/)-Gruppe: aktiv mit Laufzeit, solange aufgenommen
wird. Klick schliesst das Control Center und oeffnet die HUD-Auswahl bzw.
stoppt die laufende Aufnahme -- dasselbe wie F10 oder der Klick aufs Icon in
der Gruppe.

Nur Anzeige: Zustand und Steuerung liegen in `schalter`, die Kachel findet
dessen Instanz ueber `PluginService.getGlobalVar("schalter", "instanz")`.
Ohne geladene Gruppe steht "schalter-Gruppe fehlt" auf der Kachel, der Klick
geht dann ueber `dms ipc call schalter toggle aufnahme`.

Warum ein eigenes Plugin: das Control Center legt fuer jede Kachel eine eigene
Instanz der Plugin-Komponente an (beim Auflisten sogar eine Wegwerf-Instanz).
`schalter` mit IPC-Ziel, HUD und Dateiwaechtern liefe so mehrfach. Und pro
Plugin gibt es nur eine Kachel.

Einrichten: `dms ipc call plugins enable aufnahmeKachel`, dann im Control
Center ueber den Stift hinzufuegen (oder `plugin_aufnahmeKachel` in
`controlCenterWidgets` der settings.json).
