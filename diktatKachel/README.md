# Diktat (Kachel)

Kachel im Control Center fuer das Diktat (voxtype): aktiv beim Aufnehmen,
Sanduhr beim Transkribieren. Klick schliesst das Control Center -- es haelt
sonst den Tastaturfokus, und der Text landete im Leeren -- und schaltet wie
F12.

Aufbau wie [`aufnahmeKachel`](../aufnahmeKachel/): nur Anzeige, Zustand aus
der [`schalter`](../schalter/)-Gruppe. Ohne Gruppe geht der Klick direkt an
`voxtype record toggle`.

Einrichten: `dms ipc call plugins enable diktatKachel`, dann im Control Center
hinzufuegen (`plugin_diktatKachel` in `controlCenterWidgets`).
