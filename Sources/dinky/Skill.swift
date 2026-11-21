import DinkyCommands

let skillGuide = """
    # dinky

    Control the dinky tiling window manager with the `dinky` command.

    ## Overview

    dinky tiles macOS windows into workspaces. A workspace is a native Space,
    numbered from 1 across displays, and each has its own layout. The `dinky`
    binary is the CLI: `dinky <command>` sends the command to the running app and
    prints its reply. It exits 1 on an error or when the app isn't running. A
    command with nothing to do succeeds and says so.

    ## Use dinky terminology

    | User term or request | dinky term or command |
    | --- | --- |
    | Desktop, Space | A workspace: `dinky workspace N` |
    | Screen, monitor | A display: `dinky list-monitors` |
    | A particular window | Its ID from `dinky list-windows --all`, passed as `--window-id <id>` |
    | Stack windows | An accordion: `dinky layout accordion` |
    | Side by side | Tiles: `dinky layout tiles` |
    | Float a window, or tile it again | `dinky layout floating tiling` |
    | Maximize a window | `dinky fullscreen`, which fills the workspace; run it again to restore |
    | Even out window sizes | `dinky balance-sizes` |
    | Pause tiling | `dinky enable off`, then `dinky enable on` |
    | Shortcuts, gaps, window rules | The config file, under Configuration below |

    ## Before acting

    - Inspect the state first: `dinky list-windows --all` and
      `dinky list-workspaces --all`. Pick fields with `--format`.
    - Commands act on the focused window, which is usually the terminal you run
      in. Pass `--window-id <id>` to the commands that accept it to act on another
      window without focusing it. Switch workspaces or focus only when the request
      calls for it.

    ## Common requests

    These examples find a window by its app's bundle ID. Use the window ID from
    any `list-windows` output instead when you already have it.

    ### Find a window

    ```sh
    dinky list-windows --all --format '%{window-id} %{app-name} %{workspace} %{window-title}'
    dinky list-windows --all --app-bundle-id com.apple.TextEdit --format '%{window-id} %{window-title}'
    ```

    ### Move a window to another workspace

    ```sh
    id=$(dinky list-windows --all --app-bundle-id com.apple.TextEdit --format '%{window-id}' | head -1)
    dinky move-window-to-workspace 4 --window-id "$id"
    ```

    The user stays where they are. Add `--follow` to show the window's new
    workspace and focus it.

    ### Send a window to another display

    ```sh
    dinky move-window-to-display next --window-id "$id"
    ```

    With a single display this fails with `no other display`.

    ### Stack windows, or put them side by side

    ```sh
    dinky layout accordion --window-id "$id"
    dinky layout tiles --window-id "$id"
    ```

    Both act on the container that holds the window.

    ### Float a window, or tile it again

    ```sh
    dinky layout floating tiling --window-id "$id"
    ```

    Each run toggles the window between floating and tiled.

    ### Switch a workspace to another layout

    ```sh
    dinky workspace-layout master --window-id "$id"
    dinky workspace-layout dwindle --window-id "$id"
    ```

    The first switches the window's workspace to the master layout, the second
    switches it back.

    ## Verify and report the result

    Moving a window without `--follow` replies once the window has arrived, so
    `dinky list-windows --all` right after shows it on its new workspace.
    `workspace` and `--follow` reply before the switch finishes: for a moment,
    `dinky list-workspaces --focused` and `dinky list-windows --focused` can still
    show the previous workspace and window. Wait a second before checking them.

    Describe the result in the user's terms, such as "Moved TextEdit to workspace
    4". Mention a command that failed and its message.

    ## Desktops

    Each workspace needs a desktop. dinky creates and removes desktops only on
    macOS 27 and later. On macOS 26 and earlier, `workspace` and
    `move-window-to-workspace` fail for a workspace without a desktop with
    `workspace N has no Space`. Don't assume dinky can create desktops there,
    and don't try to add them yourself. `dinky doctor` reports each display that
    is short of desktops; ask the user to add them in Mission Control
    (Control–↑).

    ## Troubleshooting

    - `dinky: app is not running`: ask the user to open dinky. Don't start
      `dinky app` yourself.
    - `dinky doctor` checks the config, the macOS settings dinky needs, and whether
      another tiling window manager is running. It exits 1 on errors.
    - When dinky runs from Finder or at login, it logs to
      `~/Library/Logs/dinky.log`.

    ## Configuration

    The config file is `~/.config/dinky/dinky.toml`. The app reloads it on save.
    Run `dinky doctor` after editing it to check for errors. The reference is
    https://dinky.rodeo/configuration/, and the manual at https://dinky.rodeo/
    covers concepts and layouts.

    ## Commands

    \(Command.all.map { "- `\($0.syntax)`: \($0.description)" }.joined(separator: "\n"))

    ### Command line only

    \(cliOnlyCommands.map { "- `\($0.syntax)`: \($0.description)" }.joined(separator: "\n"))
    """

func runSkill() -> Int32 {
    print(skillGuide)
    return 0
}
