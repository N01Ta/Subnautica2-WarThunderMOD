# WarThunderMOD — Subnautica 2

Spawn and arrange **3D models** inside **Subnautica 2**. Built for War Thunder and GTA 5 RP integrations.

[Screenshots](#screenshots) · **Demo video:** link coming soon

> The original demo video reached ~1M views in a day. The YouTube link with a timestamp will be added here.

> **Logic-only repository.** 3D models are **not** included — see [What's not included](#whats-not-included). This repo contains the mod's Blueprint/Widget logic and documentation.

---

## Screenshots

| War Thunder: Bismarck | Model menu — «Мир вайба» |
| --- | --- |
| ![Bismarck in Subnautica 2](docs/screenshots/warthunder-bismarck.jpg) | ![Model menu](docs/screenshots/vibe-ui.jpg) |

| War Thunder: Po-2 | |
| --- | --- |
| ![Po-2 in Subnautica 2](docs/screenshots/warthunder-po2.jpg) | |

## Features

- Spawn 3D models in the world and arrange them.
- Model menu **«Мир вайба»**: choose a model, add/remove, save/load layout, clear the world.
- Controls:
  - **LMB** — select a model;
  - **arrows** — move;
  - **mouse wheel** — rotate;
  - **purple arrow** — scale;
  - **LMB on empty space** — deselect.
- Scenario and binding widgets for War Thunder / GTA 5 RP integrations.
- Blueprint/Widget logic extracted from the Subnautica 2 modkit autosave.

## What's included

| Asset | Purpose |
| --- | --- |
| `WBP_WarThunderMenu_Auto1/2` | Main model menu |
| `WBP_WarThunderBindings_Auto4/5/6` | Key bindings / input |
| `WBP_WarThunderEditor_Auto1/3` | Editor widgets |
| `WBP_WarThunderScenarios_Auto1/2` | Scenario logic |
| `ModActor_Auto3` | Mod actor |
| `*_Auto1` | Legacy auto asset |

11 `.uasset` files, ~2.5 MB total. They are Unreal assets; open them with the Subnautica 2 modkit.

## What's not included

| Excluded | Size | Why |
| --- | ---: | --- |
| `ModelsFor3D/` (8 assets) | ~89 MB | Third-party 3D models |
| `Aircraft/` (2 assets) | ~1.5 MB | Third-party aircraft models |

Add your own models to these folders. The repository intentionally contains **only logic** so it stays light and does not redistribute third-party assets.

## Install / use

1. Copy the `.uasset` files into:

   ```
   Subnautica2-Project/Saved/Autosaves/Game/Mods/WarThunderMOD/
   ```

2. Add your 3D models to `ModelsFor3D/` and `Aircraft/` (not included).
3. Launch the modkit / game and open the **«Мир вайба»** menu.
4. Choose a model, add it to the world, and arrange it with the controls above.

## Credits

> Created using the Unofficial Subnautica 2 modkit https://github.com/Subnautica2Modding/Subnautica2-Project/

## Disclaimer

Not affiliated with Unknown Worlds Entertainment, Focus Entertainment, Gaijin Entertainment, or Rockstar Games. Subnautica, War Thunder, GTA, and all related assets/trademarks belong to their respective owners. 3D models are not included.

## License

MIT for the repository's original logic and documentation. Third-party 3D models, trademarks, and game assets are not included and remain the property of their owners.
