# PlayerDB

An ArcheAge Classic addon that logs what your client sees (players, regrades, house sales and your inventory) to data files on disk.

> **Note: this addon is mostly pointless on its own.**
> PlayerDB only writes raw data files. It does not show you anything useful in-game. It is built to work together with the paired sync app, which reads those files and uploads them to the site, and you need API access to that site for any of it to go anywhere. Without the app and API access, you are just filling a folder with `.dat` files.

## Features

Each feature can be switched on or off from the addon manager's settings button. Changes apply right away and are remembered.

| Feature | Default | What it does |
| --- | --- | --- |
| Players | on | Logs targeted players, raid/party members in range, and your own character (self is logged every 3 minutes). |
| Regrades | on | Logs every regrade broadcast, with a status light for losses. |
| ForSale | on | Logs house sale events (listing, cancelling, buying, sold). Currently raw, to confirm what the client provides. |
| Inventory | off | Saves a snapshot of what your character carries shortly after load, then every 30 minutes. Click the icon to scan right away. |
| DemoOCR | off | Hands a request to the sync app through `Demos/`. Click the icon and the addon writes your location until the sync app marks the request done. If nothing answers within 10 seconds, you get an "Enable sync app" message in chat. Sounds mark each step: a start chime, a tick every 2 seconds while waiting, and different sounds for done and failed. |
| HouseTarget | on | When you target a house (WorldSatNav's demo test, plus the client's own "housing" kind), reads its name, owner and faction and works out where it stands. A building icon shows the state: gray when no house is targeted, blue with a map pin while it needs you to move within 6 m and walk around it, green with a tick once its location is saved. Walking a few metres while it stays targeted lets the addon sight it from several spots, which pins the point the game places the building at; if the camera maths fails, a distance fit to the building's collision shape is used instead. Pinned buildings are saved to `Houses/`. Everything known about the current target goes to `Demos/target.dat`. |

The settings window also has a **Reset data** button (click twice to confirm) that empties all logged data files.

## Install

1. Download the latest release from the [releases page](https://github.com/Madpeterz/PlayerDB/releases).
2. Put the `PlayerDB` folder in your ArcheAge Classic addon directory.
3. Enable PlayerDB in the in-game addon manager.

## Where the data goes

The addon writes into its own folder:

| Folder | Contents |
| --- | --- |
| `Players/` | Player entries |
| `Regrades/` | Regrade entries |
| `ForSale/` | Raw house sale events |
| `Inventory/` | One inventory snapshot per character |
| `Demos/` | `request.dat` and `location.dat`, the hand-over to the sync app; `target.dat`, the house you last targeted |
| `Houses/` | One file per located building, `<sextant hash>_<owner>.dat`, holding `sextent`, `buildingname` and `ownername` |

Every entry is stamped with the addon version it was logged by. These files are generated at runtime and are git-ignored.

## Releases

Pushing a version tag (`2.7.1` or `v2.7.1`) publishes a GitHub release through the workflow in `.github/workflows/release.yml`.

## Credits

Settings window look and clock handling follow WorldSatNav.
