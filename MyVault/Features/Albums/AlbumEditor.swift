import Foundation

/// Album rules, kept free of SwiftData and SwiftUI.
///
/// Membership changes go through here rather than being written inline in views so
/// the three promises the feature makes can be tested directly:
///
/// * deleting an album never touches the encrypted files,
/// * adding an item to an album never copies it,
/// * the primary relationship and the ID list can never disagree.
enum AlbumEditor {

    /// Trimmed name, or nil when the text is not a usable album name.
    ///
    /// Whitespace-only input is rejected rather than saved as a blank row that the
    /// user cannot then identify or rename in a list.
    static func validatedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Membership

    /// Adds `items` to `album`. Returns true when anything actually changed, so the
    /// caller can skip a save and a haptic for a no-op.
    ///
    /// An item already in the album keeps its position instead of moving to the
    /// front: re-adding a photo the user has already filed must not silently change
    /// which album is primary for it.
    @discardableResult
    static func add(_ items: [VaultMedia], to album: VaultAlbum) -> Bool {
        var changed = false
        for item in items {
            guard !item.belongs(to: album) else { continue }
            item.albumIDs.append(album.id)
            if item.album?.id != album.id {
                item.album = album
                if !album.media.contains(where: { $0.id == item.id }) { album.media.append(item) }
            }
            changed = true
        }
        return changed
    }

    /// Removes `items` from `album` only. The items, and their files, are untouched;
    /// they simply stop carrying this label.
    ///
    /// When the removed album was the item's primary album the relationship is
    /// cleared, so `VaultAlbum.media` cannot keep claiming an item that no longer
    /// carries the label.
    @discardableResult
    static func remove(_ items: [VaultMedia], from album: VaultAlbum) -> Bool {
        var changed = false
        for item in items {
            guard item.belongs(to: album) else { continue }
            item.albumIDs.removeAll { $0 == album.id }
            if item.album?.id == album.id { item.album = nil }
            changed = true
        }
        return changed
    }

    /// Drops `albumID` from every item. Called before an album row is deleted so no
    /// membership list can point at an album that no longer exists.
    ///
    /// Returns the number of items detached, which is what the delete confirmation
    /// promises to leave in the library.
    @discardableResult
    static func detachAll(in items: [VaultMedia], albumID: String) -> Int {
        var detached = 0
        for item in items where item.belongs(toAlbumID: albumID) {
            item.albumIDs.removeAll { $0 == albumID }
            if item.album?.id == albumID { item.album = nil }
            detached += 1
        }
        return detached
    }

    /// Every live item labelled with `album`, newest first.
    ///
    /// Membership is matched by ID, not by object identity, so an album opened after
    /// a relaunch — where the relationship objects are different instances — shows
    /// the same contents.
    static func items(in album: VaultAlbum, from items: [VaultMedia]) -> [VaultMedia] {
        items
            .filter { !$0.isInTrash && $0.belongs(to: album) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// IDs already filed in `album`, so the picker can disable them.
    static func memberIDs(in album: VaultAlbum, from items: [VaultMedia]) -> Set<String> {
        Set(items.filter { $0.belongs(to: album) }.map(\.id))
    }

    // MARK: - Covers

    /// The item to draw as `album`'s cover.
    ///
    /// Explicit choice first, then the newest live member. `coverMediaID` is checked
    /// against the live members rather than trusted outright: an item can be moved to
    /// Recently Deleted or purged, and a stale ID would otherwise leave the album with
    /// an empty square that reads as a bug rather than as "no cover".
    static func cover(for album: VaultAlbum, from items: [VaultMedia]) -> VaultMedia? {
        let members = self.items(in: album, from: items)
        if let chosen = album.coverMediaID,
           let match = members.first(where: { $0.id == chosen }) {
            return match
        }
        return members.first
    }

    /// Records `item` as the cover. Only an actual member may be chosen, so a cover
    /// can never point at an item outside the album.
    @discardableResult
    static func setCover(_ item: VaultMedia, for album: VaultAlbum) -> Bool {
        guard item.belongs(to: album) else { return false }
        album.coverMediaID = item.id
        return true
    }

    /// Clears an explicit cover, returning the album to its newest-item default.
    static func clearCover(for album: VaultAlbum) {
        album.coverMediaID = nil
    }

    // MARK: - Ordering

    /// Album list order. Case- and diacritic-insensitive, with the stable ID as the
    /// final tie-break.
    ///
    /// `localizedStandardCompare` alone is not enough: for names that differ only by
    /// case ("Apple" / "apple") the result is left to the locale, and on some locales
    /// it *inverts* under case folding, so the two would swap places between runs.
    /// Comparing the folded (lowercased, diacritic-insensitive) names first makes the
    /// order deterministic, and the ID keeps two truly identical names stable.
    static func sorted(_ albums: [VaultAlbum]) -> [VaultAlbum] {
        albums.sorted { lhs, rhs in
            let left = GalleryComposer.folded(lhs.name)
            let right = GalleryComposer.folded(rhs.name)
            let comparison = left.localizedStandardCompare(right)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
