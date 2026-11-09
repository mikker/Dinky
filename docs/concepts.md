---
layout: default
title: Concepts
description: Workspaces, windows, the tree, displays, rules and modes. The nouns the rest of the manual uses.
permalink: /concepts/
---

# Concepts

Seven nouns. The rest of the manual is verbs.

## Workspace

A numbered native Space. `workspaces = 5` gives you 1 to 5 across every display,
and `workspace 3` switches there in about 70 ms. Each workspace has its own
[layout](layouts.md).

<figure class="wide">
{% include figures/workspaces.svg %}
<figcaption>Two displays, five workspaces, two showing.</figcaption>
</figure>

A workspace lives on one display: the main one, unless
[`[workspace-to-display]`](configuration.md#workspace-to-display) says
otherwise. When its display leaves, it moves to the main one, windows and all,
and moves back when the display returns.

## Window

Tiled, floating or fullscreen.

<figure>
{% include figures/tiled.svg %}
{% include figures/floating.svg %}
{% include figures/fullscreen.svg %}
<figcaption><code>layout floating tiling</code> toggles the first two, <code>fullscreen</code> the third.</figcaption>
</figure>

Tiled windows share the workspace. A floating window sits where you put it,
over the tiles. Fullscreen fills the workspace, above the tiles, or the share
of its width `fullscreen-width` gives it; it is not macOS full screen. Dialogs, sheets and panels float on their own. A
[rule](#rule) decides for anything else.

## Tree

A tiled workspace is a tree. Containers lay their children along one axis, as
tiles or as an accordion. The leaves are windows.

<figure>
{% include figures/tree.svg %}
<pre>workspace · tiles ↔
├── Ghostty
└── tiles ↕
    ├── Safari
    └── accordion ↔
        ├── Mail
        └── Notes</pre>
<figcaption>Three containers, four windows.</figcaption>
</figure>

`focus`, `move` and `join-with` walk and edit it. `layout` sets a container's
mode and axis. `flatten-workspace-tree` starts over from the config.

## Display

A display is matched by pattern: `main`, `secondary`, or part of its name as
`dinky list-displays` prints it. Patterns choose where a workspace lives, a
display's gaps, and a workspace's layout while it is on that display.

```toml
[workspace-to-display]
5 = 'secondary'

[display.main]
gaps.outer.top = 44

[workspace.2.display.built-in]
layout = 'accordion'
```

## Focus

One window has focus, and its border says so. `focus left` and friends move it
to the nearest window that way; with `--boundaries all-monitors-outer-frame`,
across the display edge too. [`[focus-follows-mouse]`](configuration.md#focus-follows-mouse)
moves it with the pointer instead. When the focused window closes or is minimized
and macOS leaves no key window, focus goes to its workspace's next tile, the same
one shown by an accordion or focused after moving a window away. This also applies
when hiding or quitting the focused app leaves no key window. Existing keyboard
focus on either display is left alone; a later click, focus command or Space
switch takes precedence. Empty workspaces and native full-screen Spaces have no
tile to focus.

## Rule

When a window opens, every [`[[rules]]`](configuration.md#rules) entry that
matches it runs, in order. `layout floating` and `layout tiling` decide before
the window is placed. Any other command runs on it afterwards.

```toml
[[rules]]
app-id = 'com.apple.Music'
run = ['layout floating', 'move-window-to-workspace 5']
```

## Mode

Key bindings live in modes, one active at a time. dinky starts in `main`.
`mode service` switches to the bindings in `[mode.service]` until a binding
there switches back.

```toml
[mode.main]
alt-shift-semicolon = 'mode service'

[mode.service]
esc = ['reload-config', 'mode main']
r = ['flatten-workspace-tree', 'mode main']
```

The menu bar menu lists each command with its key in the current mode.
