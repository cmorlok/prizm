import Foundation

/// Builds the collection list an organization item is saved with (openspec change
/// `fix-collection-assignment`, design D2).
///
/// The list keeps every assignment the user cannot change (read-only, unknown, other
/// organizations') and lets the user choose only the writable part. Which ids go into the
/// collections request is decided in the Data layer: both servers change only writable
/// assignments, and Vaultwarden 1.37.4 refuses a request that contains a read-only collection
/// (live rig 2026-10-30).
nonisolated enum CollectionAssignment {

    /// - Parameters:
    ///   - original: the item's collections when the edit started.
    ///   - selectedWritable: the writable collections the user has checked.
    ///   - writableIds: every collection the user can write (in any organization).
    /// - Returns: the original ids the user cannot change (read-only, unknown, other
    ///   organizations') and the selected writable ones; original order first, then new ids in the
    ///   order given, without duplicates. A selected id that is not writable is never added.
    static func finalIds(original: [String], selectedWritable: [String], writableIds: Set<String>) -> [String] {
        let selected = Set(selectedWritable)
        var result: [String] = []
        for id in original where !result.contains(id) && (!writableIds.contains(id) || selected.contains(id)) {
            result.append(id)
        }
        for id in selectedWritable where writableIds.contains(id) && !result.contains(id) {
            result.append(id)
        }
        return result
    }

    /// The user's change applied to the collections the server holds now (design D2a).
    ///
    /// Vaultwarden 1.37.4 does not change an item's revision when its collections change (live rig
    /// 2026-10-30), so a sync while the edit sheet is open can bring in another member's collection
    /// change without a conflict. Saving the sheet's list as it is would undo that change.
    /// - Parameters:
    ///   - stored: the item's collections in the record Prizm holds now.
    ///   - original: the item's collections when the edit started.
    ///   - edited: the collections the user saves (`finalIds`).
    /// - Returns: `stored` without the ids the user removed, then the ids the user added, in order,
    ///   without duplicates.
    static func rebased(stored: [String], original: [String], edited: [String]) -> [String] {
        let removed = Set(original).subtracting(edited)
        let originalSet = Set(original)
        var result: [String] = []
        for id in stored where !removed.contains(id) && !result.contains(id) { result.append(id) }
        for id in edited where !originalSet.contains(id) && !result.contains(id) { result.append(id) }
        return result
    }
}
