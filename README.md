<img src="docs/assets/icon.png" alt="dinky" width="128">

# dinky

> oh wow. you moved a rectangle.

A tiling window manager for macOS that leaves System Integrity Protection on.

```sh
brew install --cask mikker/tap/dinky
```

[Documentation](https://dinky.rodeo)

## Quick start

Open dinky and grant Accessibility when asked. Windows tile as they open.

- `dinky workspace 3`: Switch to workspace 3.
- `dinky layout accordion`: Stack the focused container.
- `dinky doctor`: Check the config, the macOS settings dinky needs, and that no other tiler is running.

**macOS 26:** Create and remove desktops in Mission Control (Control–↑). dinky
numbers, switches and tiles existing desktops, but automatic desktop creation
and removal require macOS 27 or later. Add enough desktops on each display for
your configured workspaces; `dinky doctor` reports shortages.

Learn more:

- [Concepts](https://dinky.rodeo/concepts/) and [Layouts](https://dinky.rodeo/layouts/)
- [Configuration](https://dinky.rodeo/configuration/)
- [Commands](https://dinky.rodeo/commands/)

Window rules can match or exclude Accessibility identifiers to distinguish auxiliary
windows from documents with the same title. See [window rules](https://dinky.rodeo/configuration/#rules).

Window borders use a subtle 5% optical thickening at rounded corner midpoints,
tapering back to the configured width at the straight edges.

Per-window [`[[borders.rules]]`](docs/configuration.md#bordersrules) can hide auxiliary-window borders independently of floating/tiling, including by Accessibility `AXIdentifier`. Border-only reloads update existing windows without changing their placement.

See [border development](docs/border-development.md) for the native comparison preview and regression tests.

MIT licensed.
