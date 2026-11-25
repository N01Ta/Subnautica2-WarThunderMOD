# WarThunderMOD UE4SS runtime companion

This folder is the source for the runtime companion loaded by UE4SS. It owns
only user data outside the cooked payload:

- `Content/Paks/LogicMods/WarThunderMOD/binds.ini`
- `Content/Paks/LogicMods/WarThunderMOD/scens/*.json`

The companion discovers the installed LogicMods directory through
`IterateGameDirectories()` and never puts user data into `.pak`, `.ucas` or
`.utoc`. UI and gameplay code will call this service in later roadmap stages.
