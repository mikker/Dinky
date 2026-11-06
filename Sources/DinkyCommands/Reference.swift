// The command reference: one line of syntax and one of description per command, in the order a user
// would look for them. This list owns the set of command names and their syntax: parse errors quote it and
// `dinky help` prints it. docs/commands.md owns the prose, and DocsTests holds its table to these names.

extension Command {
    public struct Doc: Equatable, Sendable {
        public let syntax: String
        public let description: String

        /// The command name, the first word of the syntax.
        public var name: String { String(syntax.prefix { $0 != " " }) }
    }

    public static let all: [Doc] = [
        Doc(syntax: "workspace <number|prev|next>",
            description: "Show a workspace (a native Space), numbered from 1 across displays, and focus its display. "
                + "prev and next step through the focused display's workspaces."),
        Doc(syntax: "workspace-back-and-forth",
            description: "Switch to the workspace that was focused before the current one."),
        Doc(syntax: "move-window-to-workspace <number|prev|next> [--follow] [--window-id <id>]",
            description: "Move a window to a workspace. --window-id selects a window by ID; otherwise use the focused window. With --follow, switch there too."),
        Doc(syntax: "move-window-to-display <next|prev> [--follow]",
            description: "Move the focused window to the next or previous display's current workspace. With --follow, focus it there."),
        Doc(syntax: "focus <left|down|up|right> [--boundaries workspace|all-monitors-outer-frame] "
                + "[--boundaries-action stop|fail|wrap-around-the-workspace|wrap-around-all-monitors]",
            description: "Focus the neighbouring window in a direction in the layout tree. At the workspace edge, "
                + "--boundaries all-monitors-outer-frame goes on to the display in that direction and focuses the window "
                + "at its near edge. At the last edge, --boundaries-action stops (the default), fails, wraps to the far "
                + "side of the workspace, or, with all-monitors-outer-frame, to the display at the far side. "
                + "--wrap-around is short for --boundaries-action wrap-around-the-workspace. Never switches workspace."),
        Doc(syntax: "focus-monitor <left|down|up|right|next|prev|N>",
            description: "Focus the display in a direction, the next or previous one, or display N as list-monitors numbers it: its most recently focused window, "
                + "or the display itself when its workspace is empty, so workspace commands act on it."),
        Doc(syntax: "move <left|down|up|right>",
            description: "Move the focused window in a direction within the layout tree."),
        Doc(syntax: "join-with <left|down|up|right>",
            description: "Put the focused window and its neighbour in a new container."),
        Doc(syntax: "resize <smart|width|height> <+N|-N>",
            description: "Grow or shrink the focused window by N points: smart along its container, width or height along that axis."),
        Doc(syntax: "layout <tiles|accordion|horizontal|vertical|auto|h_tiles|v_tiles|h_accordion|v_accordion|floating|tiling>...",
            description: "Set the layout of the focused window's container, or float or tile the window. "
                + "tiles and accordion set the mode, horizontal, vertical and auto (follow the container's longer side) "
                + "the orientation, h_accordion and the like both. In a master layout the container is the stack, "
                + "in a scrolling layout the window's column. "
                + "With several, apply the one after the last that describes the window now, so 'layout floating tiling' "
                + "and 'layout tiles accordion' toggle. "
                + "An auto container counts as the orientation it follows now."),
        Doc(syntax: "workspace-layout <dwindle|master|scrolling>...",
            description: "Switch the focused window's workspace to its tree (dwindle, as its config gives it), "
                + "the master layout with the focused window as the master, or the scrolling layout. "
                + "The switch holds until the next. With several, apply the one after the one the workspace has now, "
                + "so 'workspace-layout dwindle master' toggles and 'workspace-layout dwindle master scrolling' cycles."),
        Doc(syntax: "fullscreen",
            description: "Toggle the focused window filling the workspace. The tree is kept."),
        Doc(syntax: "flatten-workspace-tree",
            description: "Put every window on the workspace back into its layout, in order, undoing tree edits. A scrolling workspace keeps its column widths."),
        Doc(syntax: "balance-sizes",
            description: "Give every window on the focused workspace an equal share of its container."),
        Doc(syntax: "swap-with-master",
            description: "In a master layout, swap the focused window with the master, or the master with the top of the stack. "
                + "Both keep their tiles and the focus stays with the window."),
        Doc(syntax: "retile",
            description: "Re-read every window and re-apply the layout of every workspace on screen."),
        Doc(syntax: "clear-minimum-sizes",
            description: "Forget the minimum window sizes dinky has learned for every app, and re-apply every layout."),
        Doc(syntax: "mode <name>",
            description: "Switch to a binding mode from the config, such as 'main' or 'service'."),
        Doc(syntax: "reload-config",
            description: "Reload ~/.config/dinky/dinky.toml. On an error the previous config stays."),
        Doc(syntax: "enable <on|off|toggle>",
            description: "Turn dinky on or off. Off stops tiling and restores every window to its original frame and Space."),
        Doc(syntax: "list-workspaces [--all|--focused|--monitor <focused|all|n>...] [--visible [no]] [--empty [no]] [--format <format>]",
            description: "Print workspace numbers, one per line, of the focused display by default. --all covers every display. "
                + "--focused prints the focused workspace. "
                + "Format variables: " + vars(WorkspaceQuery.variables) + "."),
        Doc(syntax: "list-windows [--all|--focused|--monitor <focused|all|n>...] [--workspace <focused|visible|n>...] "
                + "[--app-bundle-id <id>] [--format <format>]",
            description: "Print windows as 'id | app | title', of the focused display by default. --focused prints the focused window. "
                + "Format variables: " + vars(WindowQuery.variables) + "."),
        Doc(syntax: "list-monitors [--focused [no]] [--format <format>]",
            description: "Print displays as 'number | name'. Format variables: " + vars(MonitorQuery.variables) + "."),
        Doc(syntax: "list-displays [--focused [no]] [--format <format>]",
            description: "The same as list-monitors."),
        Doc(syntax: "list-modes [--current]",
            description: "Print the binding modes in the config, one per line, main first. --current prints the mode dinky is in."),
        Doc(syntax: "debug-state",
            description: "Print the tiling state as JSON: displays, each workspace's tree and expected frames, "
                + "placements and windows. For tests and bug reports."),
        Doc(syntax: "exec-and-forget <shell command>",
            description: "Run the rest of the line with /bin/sh -c without waiting. Its output goes to dinky's log."),
    ]
}

private func vars(_ names: [String]) -> String {
    (names + Format.special).map { "%{\($0)}" }.joined(separator: ", ")
}
