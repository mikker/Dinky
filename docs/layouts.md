---
layout: default
title: Layouts
description: Workspace layouts place windows, layout modes show them. Dwindle, fixed, scrolling and master; tiles and accordion.
permalink: /layouts/
---

# Layouts

Two knobs, on two levels.

- A **workspace layout** decides where a new window goes: `dwindle`, `fixed`,
  `scrolling` or `master`. One per workspace, from the config or
  `workspace-layout`.
- A **layout mode** decides how one container shows its windows: `tiles` side
  by side, or an `accordion`. One per container, from `layout`.

## Dwindle

The default. A new window splits the focused tile along its longer side. Close
it and the space goes back.

<figure class="steps">
{% include figures/dwindle-1.svg %}
{% include figures/dwindle-2.svg %}
{% include figures/dwindle-3.svg %}
{% include figures/dwindle-4.svg %}
<figcaption>Four windows open, one after the other. <code>tiles</code> is another name for it.</figcaption>
</figure>

```toml
default-layout = 'tiles'
```

## Fixed

A grid, reserved from the start. New windows fill holes left to right, top to
bottom. An empty cell stays empty.

<figure>
{% include figures/fixed.svg %}
{% include figures/fixed-expand.svg %}
<figcaption>Four windows in a 2 by 3 grid. The grid is full, so a seventh window adds a column.</figcaption>
</figure>

When every cell is taken, `expand` adds a column, a row, or an accordion in the
last cell.

```toml
[workspace.2]
layout = 'fixed'
columns = 2
rows = 3
expand = 'columns'    # columns | rows | accordion
```

## Scrolling

A row of columns wider than the display, after niri. A new window opens as a
column right of the focused one, `column-width` wide. Focusing a column scrolls
just far enough to show it whole.

<figure class="wide">
{% include figures/scrolling.svg %}
<figcaption>Columns 2 and 3 in view. macOS can't clip a window, so 1 and 4 hang off the edges with a sliver left on.</figcaption>
</figure>

`focus` and `move` go left and right between columns, up and down within one.
`join-with` puts the window into the column beside it.

```toml
[workspace.1]
layout = 'scrolling'

[scrolling]
column-width = 0.49
```

## Master

One window, the master, takes `size` of the display on `side`. The others
stack beside it, after Hyprland. The first window fills the display alone;
when the master closes, the top of the stack takes its place.

<figure>
{% include figures/master.svg %}
{% include figures/master-accordion.svg %}
<figcaption>A stack of tiles, and the same stack after <code>layout accordion</code>.</figcaption>
</figure>

`swap-with-master` trades places with the master. `resize width` changes the
master's share.

On a wide display, `side = 'center'` puts the master in the middle once two
windows are stacked, and new windows alternate between a stack on its right and
one on its left.

<figure>
{% include figures/master-center.svg %}
<figcaption>A centred master with three windows stacked.</figcaption>
</figure>

```toml
[workspace.3]
layout = 'master'

[master]
size = 0.6
side = 'left'
```

## Tiles and accordion

The two layout modes. Tiles share the container. An accordion gives it to the
focused window, with the others peeking out `padding` points on each side;
focus a neighbour and it comes to the front.

<figure>
{% include figures/tiles.svg %}
{% include figures/accordion-h.svg %}
{% include figures/accordion-v.svg %}
<figcaption>The same three windows as tiles, as an accordion, and as a vertical one.</figcaption>
</figure>

A container also has an axis: `horizontal`, `vertical`, or `auto`, the longer
side of its rectangle. `layout vertical` turns it.

## Switching

<div class="wide-table" markdown="1">

| Command | Changes | Of |
|---|---|---|
| `layout tiles\|accordion` | the mode | the focused window's container. In master the stack, in scrolling the column. |
| `layout horizontal\|vertical\|auto` | the axis | the same container. |
| `layout floating\|tiling` | tiled or not | the focused window. |
| `workspace-layout dwindle\|master\|scrolling` | the workspace layout | the focused window's workspace, until the next switch. `fixed` comes from the config only. |
| `flatten-workspace-tree` | everything, back to the config | the workspace. |

</div>

Given several names, `layout` and `workspace-layout` apply the one after the
current, so `layout tiles accordion` and `workspace-layout dwindle master`
toggle. The keys, defaults and edge cases are in
[Configuration](configuration.md) and [Commands](commands.md).
