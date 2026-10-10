import Foundation

struct WorkspaceWindowHome {
    let identity: Window.Identity
    let workspace: Int
    let title: String
}

/// Match only unique titles in the same process, after the original window has gone.
/// Candidates are restricted by the caller to new document windows during display recovery.
func workspaceReplacements(homes: [WorkspaceWindowHome], candidates: [WorkspaceWindowHome],
                           live: Set<Window.Identity>) -> [(WorkspaceWindowHome, WorkspaceWindowHome)] {
    struct Key: Hashable {
        let pid: Int32
        let title: String
    }
    let key = { (home: WorkspaceWindowHome) in Key(pid: home.identity.pid, title: home.title) }
    let originals = Dictionary(grouping: homes.filter { !$0.title.isEmpty }, by: key)
    let replacements = Dictionary(grouping: candidates.filter { !$0.title.isEmpty }, by: key)
    return originals.compactMap { key, group in
        guard group.count == 1, let old = group.first, !live.contains(old.identity),
              let matches = replacements[key], matches.count == 1, let new = matches.first else { return nil }
        return (old, new)
    }
}
