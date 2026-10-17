import SwiftUI
import UIKit

/// Adaptive thumbnail grid shared by the vault and album screens.
///
/// Only the visible cells run a load task (that is what `LazyVGrid` buys), the
/// decode happens off the main actor inside `ThumbnailCache`, and every cell shows
/// a placeholder of the same size so scrolling never re-layouts.
///
/// Layout contract: this view is the *whole* scrollable region. It fills the space it
/// is given, its content grows with the number of sections, and it never reserves
/// trailing space for navigation — the tab bar lives outside it (see `VaultView`), so
/// SwiftUI's own safe-area handling keeps the last row clear.
struct GalleryGrid: View {
    let sections: [GallerySection]
    let columnCount: Int
    let isSelecting: Bool
    @Binding var selection: Set<String>
    let onOpen: (VaultMedia) -> Void
    let onToggleSelection: (VaultMedia) -> Void

    /// Spacing between tiles. Kept tight and uniform so the grid reads as one
    /// continuous surface rather than a set of separated cards.
    private static let spacing: CGFloat = 2
    /// Vertical gap between one date section and the next. Larger than the tile
    /// spacing so grouping is legible without separators.
    private static let sectionSpacing: CGFloat = 10

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top),
            count: max(2, min(columnCount, 5))
        )
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: columns,
                alignment: .center,
                spacing: Self.spacing,
                pinnedViews: [.sectionHeaders]
            ) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            GalleryThumbCell(
                                item: item,
                                isSelecting: isSelecting,
                                isSelected: selection.contains(item.id),
                                showsAlbumBadge: item.album != nil,
                                onTap: {
                                    if isSelecting {
                                        onToggleSelection(item)
                                    } else {
                                        onOpen(item)
                                    }
                                }
                            )
                        }
                    } header: {
                        GallerySectionHeader(section: section)
                    }
                }
            }
            // Trailing room at the end of the scroll only. Group separation is done by
            // the header's own top padding, so no per-section footer is needed — a
            // section footer in `LazyVGrid` occupies a full grid row and would have
            // doubled the gap and pushed the last row away from the tab bar.
            .padding(.bottom, Self.sectionSpacing)
        }
        // Fills the viewport even when there are only one or two photos, so the grid
        // starts at the top instead of floating in the middle of the screen. The
        // content itself is never stretched: only the scroll container is.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MVColor.galleryBackground)
        // Lets the content scroll *under* the tab bar briefly while still leaving the
        // final row reachable, which is how a native photo grid behaves.
        .scrollDismissesKeyboard(.immediately)
    }
}

struct GallerySectionHeader: View {
    let section: GallerySection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
            if let subtitle = section.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Pinned headers sit on top of moving thumbnails, so the background must be
        // fully opaque: a translucent material lets the grid show through the title.
        // No divider: a native photo gallery groups by type scale and whitespace, and
        // a rule across the width makes the header read as a separate bar.
        .background(MVColor.galleryBackground)
        .accessibilityElement(children: .combine)
    }
}

/// A small thumbnail for list rows (albums, trash) where the full gallery cell
/// would be overkill. Shares the same cache, so a cover that was just drawn in the
/// gallery costs nothing here.
struct MediaThumbnailView: View {
    let item: VaultMedia
    var pixelSize: CGFloat = 200

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.isVideo ? "video" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: item.id) {
            if let cached = ThumbnailCache.shared.cachedThumbnail(for: item, pixelSize: pixelSize) {
                image = cached
            } else {
                image = await ThumbnailCache.shared.thumbnail(for: item, pixelSize: pixelSize)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One square tile. Every overlay is an alignment-scoped layer, so the layout does
/// not shift when a badge appears or a thumbnail finishes loading.
struct GalleryThumbCell: View {
    let item: VaultMedia
    let isSelecting: Bool
    let isSelected: Bool
    let showsAlbumBadge: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var didFinishLoading = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Rectangle().fill(Color(.secondarySystemFill))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    placeholder
                }
            }
            .clipped()
            // A `scaledToFill` image has no intrinsic size, so the tile must declare
            // its own square ratio *here*, inside the cell. Doing it on the outside
            // (as a modifier on the cell in the grid) double-constrained the slot and
            // produced stretched tiles on some column widths.
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) { albumBadge }
            .overlay(alignment: .topTrailing) { favoriteBadge }
            .overlay(alignment: .bottomTrailing) { durationBadge }
            .overlay(alignment: .bottomLeading) { selectionBadge }
            .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: image != nil)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .task(id: item.id) { await load() }
    }

    private var placeholder: some View {
        Group {
            if didFinishLoading && image == nil && !item.isVideo {
                // A photo that will not decode is worth flagging; a video without a
                // tile is normal (large clips keep their type icon instead).
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: item.isVideo ? "video" : "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .opacity(item.isVideo ? 0.9 : 0.5)
            }
        }
    }

    @ViewBuilder
    private var albumBadge: some View {
        if showsAlbumBadge && !isSelecting {
            MVBadge(symbol: "rectangle.stack.fill")
                .padding(5)
        }
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if item.isFavorite {
            MVBadge(symbol: "heart.fill", tint: .red)
                .padding(5)
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if item.isVideo, item.duration > 0 {
            Text(Self.durationText(item.duration))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(4)
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                .padding(4)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.fileName.isEmpty ? (item.isVideo ? "Video" : "Photo") : item.fileName]
        if item.isVideo { parts.append(Self.durationText(item.duration)) }
        if item.isFavorite { parts.append("Favorite") }
        if let album = item.album?.name { parts.append("Album \(album)") }
        return parts.joined(separator: ", ")
    }

    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    @MainActor
    private func load() async {
        if let cached = ThumbnailCache.shared.cachedThumbnail(for: item, pixelSize: 400) {
            image = cached
            didFinishLoading = true
            return
        }
        let loaded = await ThumbnailCache.shared.thumbnail(for: item, pixelSize: 400)
        guard !Task.isCancelled else { return }
        image = loaded
        didFinishLoading = true
    }
}
