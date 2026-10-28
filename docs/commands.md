---
layout: default
title: Commands
description: dinky commands, the command line and socket, and scripting a bar.
permalink: /commands/
---

# Commands

Key bindings, `dinky <command>` and the menu share one vocabulary. `dinky help`
prints it.

<div class="wide-table" markdown="1">

| Command | |
|---|---|
| `workspace <n\|prev\|next>` | Show a workspace and focus its display. `prev`/`next` step through the focused display's and don't wrap. |
| `workspace-back-and-forth` | Switch to the previous workspace. |
| `move-window-to-workspace <n\|prev\|next> [--follow]` | Move the focused window, and with `--follow` go too. |
| `move-window-to-display <next\|prev> [--follow]` | Move the focused window to another display's workspace. |
| `focus <left\|down\|up\|right> [--boundaries <b>] [--boundaries-action <a>]` | Focus the nearest window. `--boundaries` is `workspace` (default) or `all-monitors-outer-frame`, which continues onto the next display. `--boundaries-action` is `stop` (default), `fail`, `wrap-around-the-workspace` (`--wrap-around`) or `wrap-around-all-monitors`, which needs `all-monitors-outer-frame`. |
| `focus-monitor <left\|down\|up\|right\|next\|prev\|n>` | Focus a display. |
| `move <left\|down\|up\|right>` | Move the focused window in the tree. |
| `join-with <left\|down\|up\|right>` | Put the focused window and its neighbour in a new container. |
| `resize <smart\|width\|height> <+n\|-n>` | Resize by n points. |
| `layout <tiles\|accordion\|horizontal\|vertical\|auto\|h_tiles\|v_tiles\|h_accordion\|v_accordion\|floating\|tiling>...` | Set the layout of the focused window's container, or float/tile the window. In a [master layout](configuration.md#master) the container is the stack, in a [scrolling layout](configuration.md#scrolling) the window's column. Given several, applies the one after the current one, so `layout floating tiling` and `layout tiles accordion` toggle. Acts on the focused window, tiling it first if it floats, so it does nothing on an empty workspace. |
| `workspace-layout <dwindle\|master\|scrolling>...` | Switch the focused window's workspace to its tree (`dwindle`, as its config gives it), to [master](configuration.md#master) with the focused window as the master, or to [scrolling](configuration.md#scrolling). The switch holds until the next. Given several, applies the one after the current one, so `workspace-layout dwindle master` toggles and `workspace-layout dwindle master scrolling` cycles. |
| `fullscreen` | Toggle filling the workspace (not macOS full screen). [`fullscreen-width`](configuration.md#top-level) narrows and centres it. |
| `flatten-workspace-tree` | Put every window back into the workspace's layout, in order, undoing tree edits. A scrolling workspace keeps its column widths. |
| `balance-sizes` | Give every window an equal share. |
| `swap-with-master` | In a [master layout](configuration.md#master), swap the focused window with the master, or the master with the top of the stack. |
| `retile` | Re-read windows and re-apply every layout. |
| `clear-minimum-sizes` | Forget the minimum window sizes learned for every app and re-apply every layout. |
| `mode <name>` | Switch binding mode. |
| `reload-config` | Reload the config. |
| `enable <on\|off\|toggle>` | Turn dinky on or off. Off restores windows, takes their borders away and turns key bindings off too, so turn it back on from the menu or with `dinky enable on`. While off, dinky leaves new windows, `[[rules]]`, Spaces and workspaces alone; turning it on tiles what opened meanwhile, where it is. |
| `list-workspaces`, `list-windows`, `list-monitors`, `list-displays`, `list-modes` | See [Scripting](#scripting). `list-displays` = `list-monitors`. |
| `debug-state` | Tiling state as JSON, for bug reports. |
| `exec-and-forget <shell command>` | Run with `/bin/sh -c` without waiting. Output goes to the log. |

</div>

Workspaces are numbered across displays; see
[`[workspace-to-display]`](configuration.md#workspace-to-display). A full-screen
app's Space has no number, nor does the Space of a display without workspaces.

## Command line

The app binary is the CLI. `dinky <command>` sends a command to the running app
and exits 1 on errors or when it isn't running. A command with nothing to do
succeeds: `move left` on a window already at the left edge prints
`move left: nothing to do` and exits 0, as `workspace 1` does on workspace 1.
CLI-only commands:

| Command | |
|---|---|
| `app` | Run the app in the foreground, logging to the terminal. |
| `doctor [--config <path>]` | Check the config and macOS settings, and that no other tiling window manager is running. |
| `recover` | Ask the running app to restore windows a crashed session left tiled. |
| `debug events\|windows` | Print window events or windows, without the app. |
| `version`, `-v`, `--version` | Print the version and build number. |

The log is `~/Library/Logs/dinky.log`; attach it to bug reports.

Scripts can skip the CLI and talk to the socket: one command per connection,
answered with `ok` or `error` and the reply.

```sh
printf 'workspace 2\n' | nc -U "$TMPDIR/dinky.sock"
```

## Recovery

dinky journals each window's original frame and Space before tiling it. `enable
off`, quitting, `kill` and logging out put them all back. A window that can't
be put back (display gone, app not answering) stays journaled and is tried again
by the next disable, quit or `dinky recover`, unless you move it first. After a
crash, the menu offers to restore them (or `dinky recover`); dinky stays off
until `dinky enable on`.

## Scripting

The queries follow [AeroSpace](https://nikitabobko.github.io/AeroSpace/commands)'s
names, flags and output, so most AeroSpace bar scripts work by swapping the
command name.

<div class="wide-table" markdown="1">

| Query | Flags | Default format |
|---|---|---|
| `list-workspaces` | `--all`, `--focused`, `--monitor <focused\|all\|n>...`, `--visible [no]`, `--empty [no]`, `--format` | `%{workspace}` |
| `list-windows` | `--all`, `--focused`, `--monitor <focused\|all\|n>...`, `--workspace <focused\|visible\|n>...`, `--app-bundle-id <id>` (or `--app-id`), `--format` | `%{window-id}%{right-padding} \| %{app-name}%{right-padding} \| %{window-title}` |
| `list-monitors` | `--focused [no]`, `--format` | `%{monitor-id}%{right-padding} \| %{monitor-name}` |
| `list-modes` | `--current` | Mode names, `main` first |

</div>

Without a display flag, `list-workspaces` and `list-windows` cover the focused
display; `list-monitors` lists every display. `list-windows` leaves out windows
an app has hidden rather than closed, such as a settings window closed with
Cmd-W that the app keeps around. Format variables:

- `%{right-padding}`, `%{newline}`, `%{tab}`
- Workspaces: `workspace`, `workspace-is-focused`, `workspace-is-visible`,
  `workspace-layout` (`dwindle`, `fixed`, `master` or `scrolling`, empty on a
  full-screen Space), `monitor-id`, `monitor-name`, `monitor-is-main`
- Windows: `window-id`, `window-title`, `window-identifier`, `window-layout`,
  `window-parent-container-layout`, `window-is-floating`,
  `window-is-fullscreen`, `app-name`, `app-bundle-id`, `app-pid`, and the
  workspace variables

`%{monitor-is-main}` tells a bar which workspaces are on the side display.

### SketchyBar

Drive a bar from the config's [hooks](configuration.md#hooks):

```toml
[hooks]
startup = ['exec-and-forget brew services restart sketchybar']
workspace-changing = ['exec-and-forget sketchybar --trigger workspace_changing DINKY_DISPLAY=$DINKY_DISPLAY DINKY_WORKSPACE=$DINKY_WORKSPACE']
workspace-changed = ['exec-and-forget sketchybar --trigger workspace_change WORKSPACE=$DINKY_WORKSPACE']
focus-changed = ['exec-and-forget sketchybar --trigger focus_changed']
mode-changed = ['exec-and-forget sketchybar --trigger mode_changed MODE=$DINKY_MODE']
```

The workspace hooks set `DINKY_WORKSPACE` (empty on a full-screen Space),
`DINKY_PREV_WORKSPACE` and `DINKY_DISPLAY` (1-based). `workspace-changing`
fires only for dinky's own switches, so draw the target there and the real
state on `workspace-changed`, which always follows. `mode-changed` sets
`DINKY_MODE` and `DINKY_PREV_MODE`; `dinky list-modes --current` prints the
mode at any time. `exec-and-forget` has `dinky` and Homebrew on `PATH`.

### Docking

For a workspace's layout per display, use
[`[workspace.<number>.display.<pattern>]`](configuration.md#workspacenumberdisplaypattern).
For anything else, `display-changed` runs once the workspaces have moved after
a display connects or disconnects. It sets `DINKY_DISPLAYS` and
`DINKY_PREV_DISPLAYS`, the number of displays now and before;
`dinky list-monitors` names them.

```toml
[hooks]
display-changed = ['exec-and-forget [ "$DINKY_DISPLAYS" = 1 ] && ~/bin/laptop-mode.sh || ~/bin/desk-mode.sh']
```
