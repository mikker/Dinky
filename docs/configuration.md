---
layout: default
title: Configuration
description: dinky's TOML config, every key and its default, and the key syntax.
permalink: /configuration/
---

# Configuration

`~/.config/dinky/dinky.toml`, written on first run and reloaded on save.

- Every key is optional; a missing key keeps the default below. Without
  `[mode.main]` there are no bindings, without `[[rules]]` no rules.
- Unknown keys are errors. A broken config does not load: the previous one
  stays and the error shows in the menu.
- `dinky doctor [--config <path>]` also checks commands, modes and key names.
- The [JSON Schema](schemas/dinky.json) gives completion in editors that read
  Taplo's `#:schema` line, such as Zed or VS Code with Even Better TOML.

## Top level

<div class="wide-table" markdown="1">

| Key | Default | |
|---|---|---|
| `start-at-login` | `true` | Register as a login item. |
| `workspaces` | `5` | Workspaces across all displays, one native Space each. dinky creates and removes Spaces to match. |
| `default-layout` | `'tiles'` | `'tiles'` (the existing dwindle layout), `'dwindle'`, `'accordion'`, or `'fixed'`. |
| `default-tiling` | `true` | Set `false` to leave workspaces untiled unless overridden. |
| `follow-app-activation` | `true` | Cmd-Tab and Dock clicks switch Spaces the fast way. Needs the macOS "switch to a Space with open windows" setting off. |
| `float-windows-without-fullscreen` | `true` | Float windows that can't go full screen, such as Finder's copy progress, About This Mac and Calculator. Terminals and editors that can hide their title bar still tile. A `layout tiling` rule tiles a window anyway. |

</div>

## `[workspace.<number>]`

Override `default-tiling` or `default-layout` for a globally numbered
workspace. `layout = 'fixed'` reserves every cell in its template from the start.
`rows` and `columns` each default to `1`; with two columns and three rows, one
window occupies one sixth of the workspace, and an empty cell stays empty when
another window closes. New windows fill holes first, left to right, top to bottom.

When all cells are occupied, `expand` chooses what happens next: `'columns'`
(default) adds a column, `'rows'` adds a row, or `'accordion'` stacks overflow
windows in the last cell. Expansion resizes existing cells but does not rearrange
their positions. An overflow row or column disappears once empty; reserved
template cells remain. A tree command can still edit the layout; if it changes the
template structure, new windows split the focused tile instead of resetting
those edits. Changing template settings in the config rebuilds the tree once.

For example, to tile only workspace 2 (and send new Ghostty windows there using a rule):

```toml
default-tiling = false

[workspace.2]
tiling = true
layout = 'fixed'
columns = 2
rows = 3
# expand = 'columns' # or 'rows' or 'accordion'

[[rules]]
app-id = 'com.mitchellh.ghostty'
run = 'move-window-to-workspace 2'
```

`rows`, `columns`, and `expand` apply only to a fixed layout. `layout = 'accordion'`
remains available; conceptually it resembles a 1×1 fixed template with accordion
overflow, but keeps the existing accordion orientation behavior. Workspace
numbering starts at 1.

## `[accordion]`

<div class="wide-table" markdown="1">

| Key | Default | |
|---|---|---|
| `padding` | `30` | Points the neighbours peek out by. |
| `orientation` | `'auto'` | On switching to accordion, `'auto'` runs along the container's longer side; `'keep'` keeps its orientation. An orientation set with `layout` is always kept. |

</div>

## `[gaps]`

<div class="wide-table" markdown="1">

| Key | Default | |
|---|---|---|
| `inner` | `8` | Between windows. Or `{ horizontal = 8, vertical = 6 }`. |
| `outer` | `8` | To the screen edge. Or `{ top = 44, bottom = 8, left = 8, right = 8 }`, or `outer.top = 44`. |

</div>

## `[workspace-to-display]`

Which display a workspace lives on, by number. A display pattern is `main`,
`secondary` (the other one, when there are two), or part of the name from
`dinky list-displays`. A list tries each in turn. Unlisted workspaces, and
listed ones whose display isn't connected, live on the main display.

```toml
[workspace-to-display]
5 = 'secondary'         # on the side display while it's connected, else a normal workspace
4 = ['dell', 'lg']
```

When a display comes or goes, dinky moves the workspace's windows, layout
included, to a Space on its display and removes the Space left behind. Empty
leftover Spaces are removed; ones with windows are left alone, unnumbered. A
display with no workspaces keeps one unnumbered Space. Windows macOS piles onto
another workspace when a display goes away, as around sleep, go back to their
own workspace once the displays settle. Dinky also records the workspace of
hidden and minimized document windows, including inactive native tabs. Helper
windows do not count as workspace contents. For eight seconds after a display
change settles, dinky also restores replacement document windows when the old
window has closed and the same process and a unique, nonempty title identify
the replacement. Ambiguous replacements keep the workspace where they open.
During recovery, displaced windows stay out of temporary workspace layouts.
Restored windows keep their workspace when first shown after reconnecting;
the rule that new windows follow the focused display does not apply to them.
Dinky then removes empty Spaces left by temporary replacement windows.

## `[display.<pattern>]`

Per-display `gaps`, with the patterns above. Name patterns beat
`main`/`secondary`; longer names beat shorter.

```toml
[display.main]          # the display with the bar
gaps.outer.top = 44
```

## `[borders]`

<div class="wide-table" markdown="1">

| Key | Default | |
|---|---|---|
| `enabled` | `true` | |
| `width` | `4` | Points; may be fractional. |
| `active-color` | `'#e1e3e4'` | `'#rrggbb'` or `'#rrggbbaa'`. |
| `inactive-color` | `'#494d64'` | |
| `order` | `'below'` | `'above'` draws a click-through ring over the window. |
| `exclude-apps` | `[]` | Bundle IDs that get no border. |

</div>

## `[focus-follows-mouse]`

<div class="wide-table" markdown="1">

| Key | Default | |
|---|---|---|
| `enabled` | `false` | Focus the managed window the pointer rests on. Ignored while a button is down or a menu is open, and until the pointer moves to another window after Cmd-Tab or a Space change. |
| `delay-ms` | `100` | How long the pointer must rest. |
| `accordion-edges` | `true` | Resting on a peeking accordion edge focuses that window. |

</div>

## `[animations]`

<div class="wide-table" markdown="1">

| Key | Default | |
|---|---|---|
| `enabled` | `true` | Windows glide to their tiles instead of jumping. Off while macOS's Reduce Motion is on. |
| `duration-ms` | `150` | Roughly how long a window takes to arrive, up to 1000. `0` jumps. |

</div>

## `[drag]`

<div class="wide-table" markdown="1">

| Key | Default | |
|---|---|---|
| `placeholders` | `true` | While you drag a tiled window, outline the tile it came from and the tile it will swap with. |

</div>

## `[hooks]`

Commands run on events. See [Scripting](commands.md#scripting) for the
environment `exec-and-forget` gets.

<div class="wide-table" markdown="1">

| Key | Runs |
|---|---|
| `startup` | Once, after dinky has read the windows and displays. |
| `workspace-changing` | When a dinky switch starts, before it lands. |
| `workspace-changed` | When a display's workspace changes, or a switch gives up. |
| `focus-changed` | When focus changes, debounced 50 ms. |
| `mode-changed` | When the binding mode changes. Sets `DINKY_MODE` and `DINKY_PREV_MODE`. |

</div>

## `[[rules]]`

Every rule whose conditions all match a new window runs, in order. Dialogs,
sheets, panels and fixed-size windows float without one, as do windows that
can't go full screen while `float-windows-without-fullscreen` is on.

New windows open on the focused display, whichever display the app picked. A
rule that runs a command other than `layout` for a window, such as
`move-window-to-workspace`, decides where it goes instead.

<div class="wide-table" markdown="1">

| Key | |
|---|---|
| `app-id` | Bundle ID. |
| `app-name` | Case-insensitive regex. |
| `title` | Case-insensitive regex. |
| `kind` | `'normal'`, `'dialog'`, `'sheet'` or `'panel'`. |
| `run` | Required. A command or a list. |

</div>

```toml
[[rules]]
app-id = 'com.apple.Music'
run = ['layout floating', 'move-window-to-workspace 5']
```

## `[mode.<name>]`

Key bindings. dinky starts in `main`; `mode <name>` switches. Each key maps to
a command or a list of commands. Bound keys are swallowed.

### Keys

Modifiers (`alt`, `ctrl`, `cmd`, `shift`) and one key, joined by `-`:
`alt-shift-h`, `ctrl-left`, `f5`. Names follow a US layout.

- `a`–`z`, `0`–`9`, `f1`–`f20`
- `minus` `equal` `left-bracket` `right-bracket` `backslash` `semicolon`
  `quote` `comma` `period` `slash` `backtick` `section`
- `space` `enter` `esc` `backspace` `tab` `forward-delete` `left` `down` `up`
  `right` `page-up` `page-down` `home` `end`
- `keypad-0`–`keypad-9`, `keypad-clear` `keypad-decimal` `keypad-divide`
  `keypad-enter` `keypad-equal` `keypad-minus` `keypad-multiply` `keypad-plus`

The default `alt-` bindings take over Option-letter characters.

## Default config

```toml
#:schema https://dinky.rodeo/schemas/dinky.json
# ~/.config/dinky/dinky.toml. Saved changes take effect at once.
# A key you leave out keeps the value shown here.
# Every key and command: https://dinky.rodeo/configuration/

start-at-login = true
workspaces = 5                  # across all displays, one native Space each
default-layout = 'tiles'        # tiles (dwindle) | dwindle | accordion | fixed
default-tiling = true           # false leaves workspaces untiled unless overridden
follow-app-activation = true    # Cmd-Tab and Dock clicks switch Spaces the fast way
float-windows-without-fullscreen = true   # progress windows, About, Calculator and the like float

# Example: only tile workspace 2 in a fixed 2x3 template.
# Empty cells stay empty; a seventh window adds a column by default.
# default-tiling = false
# [workspace.2]
# tiling = true
# layout = 'fixed'
# columns = 2
# rows = 3
# expand = 'columns'           # columns | rows | accordion (overflow in last cell)

[accordion]
padding = 30                    # points the neighbours peek out by
orientation = 'auto'            # auto: run along the container's longer side | keep

[gaps]
inner = 8                       # or { horizontal = 8, vertical = 8 }
outer = 8                       # or { top = 8, bottom = 8, left = 8, right = 8 }

# Display patterns: main, secondary, or part of a name as `dinky list-displays` prints it.
# A workspace lives on the first display its patterns match, else on the main display.
# [workspace-to-display]
# 5 = 'secondary'

# Overrides for one display.
# [display.main]
# gaps.outer.top = 44

[borders]
enabled = true
width = 4
active-color = '#e1e3e4'        # '#rrggbb' or '#rrggbbaa'
inactive-color = '#494d64'
order = 'below'                 # below | above (a click-through ring over the window)
exclude-apps = []               # bundle IDs whose windows get no border

[focus-follows-mouse]
enabled = false
delay-ms = 100                  # how long the pointer rests on a window before it takes focus
accordion-edges = true          # resting on a peeking accordion edge focuses that window

[animations]
enabled = true                  # windows glide to their tiles; off while Reduce Motion is on
duration-ms = 150               # roughly how long a window takes to arrive

[drag]
placeholders = true             # outline where a dragged tile came from and the tile it will swap with

# dinky commands run on events. exec-and-forget gets $DINKY_WORKSPACE, $DINKY_PREV_WORKSPACE, $DINKY_DISPLAY,
# and $DINKY_MODE, $DINKY_PREV_MODE in mode-changed.
# [hooks]
# startup = ['exec-and-forget brew services restart sketchybar']
# workspace-changed = ['exec-and-forget sketchybar --trigger workspace_change']
# focus-changed = []
# mode-changed = []

# Every rule whose conditions all match a new window runs, in order.
[[rules]]
app-id = 'com.apple.systempreferences'   # also: app-name, title (regexes), kind (normal|dialog|sheet|panel)
run = 'layout floating'

[mode.main]
ctrl-left = 'workspace prev'
ctrl-right = 'workspace next'
alt-1 = 'workspace 1'
alt-2 = 'workspace 2'
alt-3 = 'workspace 3'
alt-4 = 'workspace 4'
alt-5 = 'workspace 5'
alt-6 = 'workspace 6'
alt-7 = 'workspace 7'
alt-8 = 'workspace 8'
alt-9 = 'workspace 9'
alt-shift-1 = 'move-window-to-workspace 1'
alt-shift-2 = 'move-window-to-workspace 2'
alt-shift-3 = 'move-window-to-workspace 3'
alt-shift-4 = 'move-window-to-workspace 4'
alt-shift-5 = 'move-window-to-workspace 5'
alt-shift-6 = 'move-window-to-workspace 6'
alt-shift-7 = 'move-window-to-workspace 7'
alt-shift-8 = 'move-window-to-workspace 8'
alt-shift-9 = 'move-window-to-workspace 9'
alt-tab = 'workspace-back-and-forth'
alt-h = 'focus left'
alt-j = 'focus down'
alt-k = 'focus up'
alt-l = 'focus right'
alt-shift-h = 'move left'
alt-shift-j = 'move down'
alt-shift-k = 'move up'
alt-shift-l = 'move right'
alt-minus = 'resize smart -50'
alt-equal = 'resize smart +50'
alt-f = 'fullscreen'
alt-shift-f = 'layout floating tiling'
alt-comma = 'layout accordion'
alt-slash = 'layout tiles'
alt-shift-n = 'move-window-to-display next'
alt-shift-semicolon = 'mode service'

[mode.service]
esc = ['reload-config', 'mode main']
r = ['flatten-workspace-tree', 'mode main']
alt-shift-h = ['join-with left', 'mode main']
alt-shift-j = ['join-with down', 'mode main']
alt-shift-k = ['join-with up', 'mode main']
alt-shift-l = ['join-with right', 'mode main']
```
