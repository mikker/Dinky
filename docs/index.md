---
layout: default
title: Documentation
description: A tiling window manager for macOS that leaves System Integrity Protection on.
permalink: /
---

<img class="app-icon" src="{{ '/assets/icon.png' | relative_url }}" alt="dinky's icon: a sketched face, laughing" width="128" height="128">

# Tiling on native Spaces, SIP left on.

<p class="tagline">oh wow. you moved a rectangle.</p>

<pre><code>$ dinky workspace 3
$ dinky list-windows --workspace 3
4211 | Ghostty | ~
4388 | Safari  | dinky
$ dinky layout accordion <span class="cursor">█</span></code></pre>

Latest release: **{{ site.version }}**

dinky tiles the windows on each native Space and switches Spaces in about 70 ms
instead of half a second. It has an accordion mode, focus borders, a TOML
config and a `dinky` command line for scripts and bars. Nothing is injected
into the Dock.

It is not a compositor: macOS still draws every window. No scrolling layouts;
windows glide to their tiles by being moved there, frame by frame.

Status: early, in daily use by its author on macOS 27. Expect rough edges.

> **Private APIs.** macOS has no public way to switch Spaces quickly or move a
> window between them, so dinky uses a synthetic Dock swipe and a few private
> SkyLight calls. A macOS update can break them.

## Requirements

- macOS 15 or later on Apple silicon. Developed and tested on macOS 27.
- Accessibility permission. The first run asks.

## Install

```sh
brew install --cask mikker/tap/dinky
open -a dinky
```

Or [download the app](https://github.com/mikker/Dinky/releases/latest/download/dinky.app.zip)
and drag it to Applications, then put the command line on your `PATH`:

```sh
ln -s /Applications/dinky.app/Contents/MacOS/dinky /usr/local/bin/dinky
```

dinky lives in the menu bar and updates itself.

### From source

Needs Swift 6 and [`just`](https://github.com/casey/just).

```sh
git clone https://github.com/mikker/Dinky.git && cd Dinky
IDENTITY="Apple Development: Your Name (TEAMID)" just install
open build/dinky.app
```

`just install` builds and signs `build/dinky.app` and links the CLI into
`~/.local/bin`. Sign with a stable identity
(`security find-identity -p codesigning`): macOS ties the Accessibility grant
to the signature, so ad-hoc builds lose it on every rebuild.

## First run

dinky writes `~/.config/dinky/dinky.toml`, asks for Accessibility, and offers
once to turn off "When switching to an application, switch to a Space with
open windows" (Desktop & Dock > Mission Control). With that off, Cmd-Tab and
Dock clicks switch Spaces the fast way instead of sliding. Saying no is fine.

The menu bar shows the current workspace. Its menu has every command, each with
the key bound to it in the current mode. `dinky doctor` checks the config and
the macOS settings dinky depends on.

Run one tiling window manager at a time. With AeroSpace, Amethyst, yabai or
KiwiDesk also running, each undoes the other's layouts; dinky shows a `!` in the
menu bar and says which one to quit.

## Uninstall

Quit dinky, delete the app and `~/.config/dinky`, and remove it from
Accessibility and Login Items. To get the Cmd-Tab slide back:

```sh
defaults write com.apple.dock workspaces-auto-swoosh -bool true && killall Dock
```

## Known limits

- Only one display has been tested properly. Switching a display the pointer
  is not on may flicker the pointer.
- dinky creates and removes Spaces to keep one per workspace, but leaves a
  leftover Space with windows alone.
- Apps refuse some sizes (Safari's minimum width, Terminal's grid). dinky lays
  out around them, but tiles can overlap or leave gaps. It remembers each app's
  minimum size; Clear Saved Minimum Sizes in the menu forgets them.
- macOS cannot focus a window on another Space, so dinky switches first.

## Credits

- [yabai](https://github.com/asmvik/yabai) (MIT): SkyLight signatures, window
  filtering, focus and event handling. SIP-on paths only.
- [mimi](https://github.com/y3owk1n/mimi) (MIT): the fast Dock swipe and the
  SkyLight symbol lookup.
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) (MIT): key syntax,
  commands and the accordion.
- [JankyBorders](https://github.com/FelixKratz/JankyBorders) (GPL-3.0): borders,
  studied only.
- [Tuna](https://tunaformac.com): an earlier Dock swipe.
- [bobrwm](https://github.com/bobrwm/bobrwm) (MIT): creating Spaces.

MIT licensed.
