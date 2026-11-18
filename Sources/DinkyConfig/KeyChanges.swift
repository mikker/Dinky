/// A renamed configuration key. Old names keep loading, with a warning naming the new name and version.
/// `table` is the dotted path without array indices: `rules`, not `rules[0]`; "" means the top level.
struct KeyChange {
    let table: String
    let old: String
    let new: String
    let version: String

    static let shipped = [
        KeyChange(table: "master", old: "orientation", new: "side", version: "0.23")
    ]
}
