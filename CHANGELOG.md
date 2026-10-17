# Changelog

## Unreleased

- New `[drag] hold-to-split = true` splits a tile on a drop: hold a dragged window still over another tile for half a second and it takes the half the pointer is in instead of swapping. `hold-ms` sets the wait. Off by default.

## 0.19

### Tiling

- New `[workspace.<number>.display.<pattern>]` tables give a workspace other settings while it is on one display, such as two fixed columns on an ultrawide and an accordion on the laptop screen. When you dock or undock, the workspace switches layout as it moves.
- Switching workspaces is lighter and no longer sets windows gliding. A switch reads only the workspace you arrive at and lays it out only if something changed there while you were away, so its windows are in place as it shows.
- Dragging a window is lighter, so the drag stays smooth and its border keeps up.

### Key bindings

- `hyper` and `meh` name the usual modifier combinations: `hyper-1` is `alt-ctrl-cmd-shift-1`, and `meh-1` is `alt-ctrl-shift-1`.

### Rules

- New `app-id-regex` key matches the bundle ID by regex, like `app-name` does for the app's name: `app-id-regex = '^com\.jetbrains\.'` covers every JetBrains app with one rule. `app-id` still matches exactly.

### Hooks

- New `display-changed` hook runs when a display connects or disconnects, once the workspaces have moved, with `DINKY_DISPLAYS` and `DINKY_PREV_DISPLAYS` set to how many displays there are now and were before. React to docking and undocking without Hammerspoon.
- `exec-and-forget` has `dinky` itself on `PATH`, so hook scripts can call `dinky` when the app was started from Finder.

### Fixes

- Turning dinky off takes its borders away and leaves window drags alone: no drop outlines, and no swap or resize remembered for when it comes back on.
- dinky keeps tiling a window after its app closes and reopens it, as Slack does when you close its window with Cmd-W and open it again from the Dock.
- Terminal windows shrink again. Terminal sizes its windows in whole rows and columns, so it never lands exactly on its tile; a size now counts as a minimum only when the window comes back at it for two different sizes asked, so that miss no longer passes for one. Minimum sizes saved by earlier versions are forgotten once.
- `move`, `join-with` and `resize` succeed when there is nothing to do, such as `move left` on a window already at the left edge: the CLI prints `move left: nothing to do` and exits 0, so launchers like LeaderKey show no error.
- A `layout` command keeps a `fixed` workspace's template when it leaves its shape alone, such as one that changes nothing or turns the overflow accordion vertical, so later windows still fill the grid.
- Releases say they need Apple silicon, so a dinky built from source on an Intel Mac doesn't offer to update itself to one, and `brew install` stops with a clear message.

## 0.18

### Key bindings

- New `[modifiers]` table picks which key of each modifier pair your bindings answer to: `'both'` (the default), `'left'` or `'right'`. With `alt = 'left'`, left Option runs dinky's bindings and right Option types special characters like `˙` and `≈` as usual.

## 0.17

### Menu

- Layout > Scrolling switches the focused window's workspace to the scrolling layout.

### Fixes

- Switching more than one workspace away no longer stops on the workspaces in between. Before, macOS briefly activated the app on each one it passed, which put that app into the Cmd-Tab order. Multi-step switches are faster too.
- Borders stay on while focus moves during an animation, such as scrolling the scrolling layout. Before, the borders of the window losing focus and the one gaining it blinked off until the windows arrived.
- Switching workspaces works with natural scrolling off. Before, on macOS 27 the swipe went the wrong way and bounced back to the workspace you were on, and following an app from the Dock or Cmd-Tab failed the same way.
- Switching workspaces on macOS before 27 uses the swipe those versions understand. Before, it bounced back there too.

## 0.16

### Tiling

- New `scrolling` layout, after niri and Hyprland: windows open as columns in a row that scrolls past the display edges to the focused one. Columns are 0.49 of the display wide by default, as Omarchy sets them (`[scrolling] column-width`); a lone column fills the display. Columns out of view hang off the edge with a sliver showing, an inner gap from the columns in view, or wait behind the columns in view where another display is beyond.
- `layout scrolling` switches the focused workspace to scrolling and `layout tiles` or `accordion` back, and `layout` with several names now cycles through them: `layout tiles accordion scrolling`.

## 0.15

### Tiling

- New windows open on the focused display, unless a rule moves them.

### Fixes

- An empty workspace activates Finder, even with the desktop turned off, so typing no longer goes to an app on another workspace.

## 0.14

### Install

- The Homebrew cask installs on macOS 15 or later, as the app supports. Before, it asked for a newer macOS.

### Command line

- `dinky -v` prints the version, like `dinky version` and `dinky --version`.

### Fixes

- Switching to an empty workspace keeps focus on its display. Before, macOS could hand focus to a window on another display, so typing and the next `workspace next` went there. `focus-monitor` onto an empty display also takes the keyboard off the other display's window.

## 0.13

### Tiling

- Windows that can't go full screen float on their own, like Finder's copy progress window, About This Mac and Calculator. Terminals and editors that can hide their title bar still tile. Set `float-windows-without-fullscreen = false` to tile them as before, or tile a single app with a `layout tiling` rule.

## 0.12

### Fixes

- Cmd-Tab to an app on another workspace brings that app's window to the front when you get there. Before, another app could stay in front, and for an app with windows on several workspaces dinky could go to the wrong one.

## 0.11

### Fixes

- Obsidian and other Electron apps tile again. Their windows could keep a slot in the layout while staying where they were, with other windows tiling around the empty slot.

## 0.10

### Scripting

- `dinky list-modes --current` prints the binding mode dinky is in, and `mode-changed` hooks get `$DINKY_MODE` and `$DINKY_PREV_MODE`, so a bar can show the mode.

### Menu

- Clear Saved Minimum Sizes in the menu, or `dinky clear-minimum-sizes`, forgets the minimum window sizes dinky has learned for each app, so windows can tile smaller again after an app lowers its minimum.

## 0.9

### Menu

- The menu bar menu has every command: focus, move, join, resize, layout, displays and modes as well as workspaces. Each item shows the key bound to it, and bindings no item covers are listed under Other Key Bindings.

## 0.8

### Fixes

- Sleeping and waking, or anything else that makes displays drop out and come back, no longer piles other workspaces' windows onto workspace 1. Once the displays settle, each window goes back to its workspace.
- After displays come or go, windows that apps moved around on hidden workspaces snap straight back into their tiles when you next visit, instead of gliding in from wherever the app put them.
- `workspace prev` and `workspace next` no longer get stuck on a display with nothing on it. A display focused with `focus-monitor` or `focus --boundaries all-monitors-outer-frame` stops counting as focused once dinky focuses a window or a display comes or goes, even when that window had focus before.

## 0.7

### Fixes

- Unplugging the display dinky was animating on no longer leaves windows stuck mid-glide at odd sizes. Animations continue on the display that is main now, and a glide that stalls for any other reason lands its windows within a couple of seconds.

## 0.6

### Motion

- Windows take about 150 ms to glide to their tiles by default, up from 50. Set `[animations] duration-ms` to change it.

### Fixes

- The minimum sizes dinky learns for an app are kept across quits and `enable off`; restoring windows no longer overwrites them with the ones from launch.
- A new window that reuses a closed window's id is tiled instead of being left where it opened.
- When macOS moves a display's Spaces to another display, their layouts move with them instead of starting over.
- A minimized window keeps its border, hidden, instead of getting a new one when it comes back.
- `move-window-to-display --follow` focuses the moved window as reliably as `move-window-to-workspace --follow` does, instead of sometimes leaving the layout behind on the old window.
- `dinky help` says what `enable off` does: it stops tiling and restores every window.

## 0.5

### Motion

- Windows glide to their tiles instead of jumping. Set the speed with `[animations] duration-ms` (50 by default) or turn it off with `enabled = false`. It's off while macOS's Reduce Motion is on.
- While you drag a tiled window, dinky outlines the tile it came from and the tile it will swap with. The window now swaps with the tile under the pointer, not the one under its centre. `[drag] placeholders = false` turns the outlines off.

### Layouts

- `flatten-workspace-tree` puts windows back into the workspace's configured layout: a fixed grid gets its cells back, and an accordion workspace becomes an accordion again.
- `move` past the edge of an accordion that fills the workspace takes the window out of it, into a tile beside the accordion, as in AeroSpace.

### Other

- dinky warns when another window manager is also running, with a `!` in the menu bar, a line in the menu and in `dinky doctor`. Two window managers undo each other's layouts, which looks like dinky failing to tile.
- The update window shows what changed, and every release is listed at [dinky.rodeo/changelog](https://dinky.rodeo/changelog/).

### Fixes

- Clicking between two windows of the same app moves focus and the border to the window you clicked.
- A window put into native full screen, or slow to finish a resize, no longer teaches dinky that its app can't shrink. That could leave every window of the app filling the screen.

## 0.4

**Upgrading:** workspaces are now numbered across all displays. `workspaces` is the total rather than a count per display, and `workspaces` inside `[display.<pattern>]` is now a config error. Use `[workspace-to-display]` to put a workspace on a particular display.

### Workspaces

- Workspace numbers stay put when you dock or undock. Each workspace is one Space, on the main display unless `[workspace-to-display]` places it elsewhere.
- dinky removes Spaces it no longer needs instead of letting leftovers pile up.
- Tiled windows keep their layout when their workspace moves to another display.
- `workspace N` goes to whichever display the workspace is on; `workspace prev` and `next` step through the focused display's workspaces.
- Queries, hooks and the menu bar use the new global numbers.

### Layouts

- New `fixed` layout: give a workspace a grid with `[workspace.N]` `columns` and `rows`. New windows fill empty cells without resizing the others; when the grid is full, `expand` adds a column, adds a row, or stacks windows in the last cell.
- `default-tiling = false` leaves workspaces untiled unless a `[workspace.N]` table turns tiling on.
- `dwindle` is accepted as another name for the `tiles` layout.

### Fixes

- Cmd-Tab to Helium and Safari web apps switches Spaces again.
- `workspace-back-and-forth` returns to the workspace you were on, not a Space you swiped past.
