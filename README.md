# PlayerDB

An ArcheAge Classic addon that logs what your client sees (players, houses, regrades, house sales and your inventory) to data files on disk.

> **Note: this addon is mostly pointless on its own.**
> PlayerDB only writes raw data files. It does not show you anything useful in-game. It is built to work together with the paired sync app, which reads those files and uploads them to the site, and you need API access to that site for any of it to go anywhere. Without the app and API access, you are just filling a folder with `.dat` files.

## Features

Each feature can be switched on or off from the addon manager's settings button. Changes apply right away and are remembered.

| Feature | Default | What it does |
| --- | --- | --- |
| Players | on | Logs targeted players, raid/party members in range, and your own character (self is logged every 3 minutes). |
| Houses | on | Logs targeted buildings with their owner and position. |
| Regrades | on | Logs every regrade broadcast, with a status light for losses. |
| ForSale | on | Logs house sale events (listing, cancelling, buying, sold). Currently raw, to confirm what the client provides. |
| Inventory | off | Saves a snapshot of what your character carries shortly after load, then every 30 minutes. Click the icon to scan right away. |
| DemoOCR | off | Hands a request to the sync app through `Demos/`. Click the icon and the addon writes your location until the sync app marks the request done. If nothing answers within 60 seconds, you get an "Enable sync app" message in chat. |

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
| `Houses/` | House entries |
| `Regrades/` | Regrade entries |
| `ForSale/` | Raw house sale events |
| `Inventory/` | One inventory snapshot per character |
| `Demos/` | `request.dat` and `location.dat`, the hand-over to the sync app |

Every entry is stamped with the addon version it was logged by. These files are generated at runtime and are git-ignored.

## Releases

Pushing a version tag (`2.7.1` or `v2.7.1`) publishes a GitHub release through the workflow in `.github/workflows/release.yml`.

## Credits

Settings window look and clock handling follow WorldSatNav.
