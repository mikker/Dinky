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
| `focus <left\|down\|up\|right> [--boundaries <b>] [--boundaries-action <a>]` | Focus the nearest window. `--boundaries all-monitors-outer-frame` continues onto the next display. `--boundaries-action` is `stop`, `fail`, `wrap-around-the-workspace` (`--wrap-around`) or `wrap-around-all-monitors`. |
| `focus-monitor <left\|down\|up\|right\|next\|prev\|n>` | Focus a display. |
| `move <left\|down\|up\|right>` | Move the focused window in the tree. |
| `join-with <left\|down\|up\|right>` | Put the focused window and its neighbour in a new container. |
| `resize <smart\|width\|height> <+n\|-n>` | Resize by n points. |
| `layout <tiles\|accordion\|horizontal\|vertical\|auto\|h_tiles\|v_tiles\|h_accordion\|v_accordion\|floating\|tiling>...` | Set the container's layout, or float/tile the window. Given several, applies the first that isn't current, so `layout floating tiling` toggles. |
| `fullscreen` | Toggle filling the workspace (not macOS full screen). |
| `flatten-workspace-tree` | Put every window back into the workspace's configured layout. |
| `balance-sizes` | Give every window an equal share. |
| `retile` | Re-read windows and re-apply every layout. |
| `clear-minimum-sizes` | Forget the minimum window sizes learned for every app and re-apply every layout. |
| `mode <name>` | Switch binding mode. |
| `reload-config` | Reload the config. |
| `enable <on\|off\|toggle>` | Turn dinky on or off. Off restores windows. |
| `list-workspaces`, `list-windows`, `list-monitors`, `list-displays`, `list-modes` | See [Scripting](#scripting). `list-displays` = `list-monitors`. |
| `debug-state` | Tiling state as JSON, for bug reports. |
| `exec-and-forget <shell command>` | Run with `/bin/sh -c` without waiting. Output goes to the log. |

</div>

Workspaces are numbered across displays; see
[`[workspace-to-display]`](configuration.md#workspace-to-display). A full-screen
app's Space has no number, nor does the Space of a display without workspaces.

## Command line

The app binary is the CLI. `dinky <command>` sends a command to the running app
and exits 1 on errors or when it isn't running. CLI-only commands:

| Command | |
|---|---|
| `app` | Run the app in the foreground, logging to the terminal. |
| `doctor [--config <path>]` | Check the config and macOS settings, and that no other tiling window manager is running. |
| `recover` | Restore unfinished window frames and surviving original Spaces. |
| `debug events\|windows` | Print window events or windows, without the app. |
| `version`, `-v`, `--version` | Print the version and build number. |

The log is `~/Library/Logs/dinky.log`; attach it to bug reports.

Scripts can skip the CLI and talk to the socket: one command per connection,
answered with `ok` or `error` and the reply.

```sh
printf 'workspace 2\n' | nc -U "$TMPDIR/dinky.sock"
```

## Recovery

dinky saves each window's untiled frame before managing it. `enable off`, quitting,
`kill` and logging out return windows to their original native Spaces when those
Spaces still exist. If an original Space was deleted or its display is unavailable,
the window stays on its current Space. Frames are translated relative to the
destination monitor and clamped within its usable bounds.

Unreachable frames and unconfirmed Space moves stay in the journal. Dinky does not switch Spaces to restore them.
Show the windows and use `dinky recover` to try again. The menu lists unfinished
windows from the current or a previous session. Recovery leaves dinky disabled
until `dinky enable on`. Closed windows are discarded; new windows do not
inherit their recovery records.

## Session restoration

dinky saves the latest managed arrangement in `session.json`, separately from
the original untiled frames in `journal.json`. On restart, it restores tree
order, container layouts, split ratios and fullscreen state.
Floating choices and frames are saved too. Current window rules and workspace
layout settings take precedence.

On startup, dinky reverses its own undo moves to restore the managed arrangement.
A window moved elsewhere while dinky is off keeps its new Space. If a saved Space
was deleted, dinky uses the replacement Space bound to the saved workspace number,
after its normal workspace arrangement. If no replacement exists, restoration is
skipped. Older snapshots without workspace numbers cannot recover deleted Spaces.
Closed windows and windows from a new app process are skipped; apps are not reopened.

Trees restore before their first tiling pass. Inactive Spaces restore when you
visit them; hidden and minimized floating windows restore when shown. Normal
window events trigger restoration, without switching desktops or polling for
windows. Frames adapt to the current monitor. A floating frame is attempted once; failed
writes are logged.

Changes are saved atomically after a half-second event burst, and immediately
before disabling or quitting. Restoring untiled frames does not overwrite the
saved managed arrangement. Tiling animation frames are not stored. Like the
recovery journal, the session file identifies surviving windows by window ID,
owner process and app launch date; it does not match recreated windows by title.

## Scripting

The queries follow [AeroSpace](https://nikitabobko.github.io/AeroSpace/commands)'s
names, flags and output, so most AeroSpace bar scripts work by swapping the
command name.

<div class="wide-table" markdown="1">

| Query | Flags | Default format |
|---|---|---|
| `list-workspaces` | `--all`, `--focused`, `--monitor <focused\|all\|n>...`, `--visible [no]`, `--empty [no]`, `--format` | `%{workspace}` |
| `list-windows` | `--all`, `--focused`, `--monitor <focused\|all\|n>...`, `--workspace <focused\|visible\|n>...`, `--app-bundle-id <id>`, `--format` | `%{window-id}%{right-padding} \| %{app-name}%{right-padding} \| %{window-title}` |
| `list-monitors` | `--focused [no]`, `--format` | `%{monitor-id}%{right-padding} \| %{monitor-name}` |
| `list-modes` | `--current` | Mode names, `main` first |

</div>

Without a display flag, queries cover the focused display. Format variables:

- `%{right-padding}`, `%{newline}`, `%{tab}`
- Workspaces: `workspace`, `workspace-is-focused`, `workspace-is-visible`,
  `monitor-id`, `monitor-name`, `monitor-is-main`
- Windows: `window-id`, `window-title`, `window-layout`,
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
mode at any time. `exec-and-forget` has Homebrew on `PATH`.
