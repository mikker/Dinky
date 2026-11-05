/// Configuration compatibility policy: old names load forever, with a warning naming the new name and version.
struct KeyChanges {
    var keys: [KeyChange]
    var values: [ValueChange]

    static let shipped = KeyChanges(
        keys: [KeyChange(table: "master", old: "orientation", new: "side", version: "0.23")],
        values: []
    )
}

/// A key renamed to `new`, or removed when `new` is nil. `table` is the dotted path of the table holding it,
/// "" for the top level, without array indices: `rules`, not `rules[0]`.
struct KeyChange {
    let table: String
    let old: String
    let new: String?
    let version: String
}

/// A renamed value of a choice key, such as a layout name.
struct ValueChange {
    let table: String
    let key: String
    let old: String
    let new: String
    let version: String
}
