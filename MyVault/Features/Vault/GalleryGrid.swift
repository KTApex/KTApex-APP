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
    let density: GalleryDensity
    let isSelecting: Bool
    @Binding var selection: Set<String>
    let onOpen: (VaultMedia) -> Void
    let onToggleSelection: (VaultMedia) -> Void
    /// Called when a pinch changes density, so the owner can persist it.
    var onDensityChange: ((GalleryDensity) -> Void)? = nil
    /// Whether tiles preserve their original aspect ratio ("Aspect Ratio Grid") vs uniform squares ("Square Photo Grid").
    var useAspectRatioTiles: Bool = false
    /// Toggles selection for an entire date section at once (iPhone Photos "Select" in section header).
    var onToggleSectionSelection: ((GallerySection) -> Void)? = nil
    /// Context-menu quick actions on individual tiles.
    var onToggleFavorite: ((VaultMedia) -> Void)? = nil
    var onShareItem: ((VaultMedia) -> Void)? = nil
    var onTrashItem: ((VaultMedia) -> Void)? = nil
    /// Summary text rendered at the bottom of the scroll view, matching Apple Photos.
    var footerSummary: String? = nil

    @Environment(\.displayScale) private var displayScale

    /// Width last reported by the background GeometryReader. Stored in state so the
    /// columns are derived once per change instead of on every body pass.
    @State private var measuredWidth: CGFloat = 0

    /// Spacing between tiles. Kept tight and uniform so the grid reads as one
    /// continuous surface rather than a set of separated cards. Wider thumbnails get
    /// slightly more air, which keeps large tiles from looking squeezed together.
    private var spacing: CGFloat {
        switch density {
        case .compact: return 1.5
        case .standard: return 2
        case .comfortable, .large: return 3
        }
    }

    /// Vertical gap between one date section and the next. Larger than the tile
    /// spacing so grouping is legible without separators.
    private static let sectionSpacing: CGFloat = 10

    var body: some View {
        // The column count comes from the width the grid is actually given, not from
        // the screen, so rotation also resolves correctly. The width is measured by an
        // invisible zero-height row that *reports* through a preference and adds no
        // layout height of its own — wrapping the scroll view in a GeometryReader would
        // collapse its height, and a fixed screen width would ignore landscape.
        ScrollView(.vertical) {
            LazyVGridLayout(
                sections: sections,
                density: density,
                spacing: spacing,
                isSelecting: isSelecting,
                selection: $selection,
                displayScale: displayScale,
                measuredWidth: measuredWidth,
                useAspectRatioTiles: useAspectRatioTiles,
                onOpen: onOpen,
                onToggleSelection: onToggleSelection,
                onToggleSectionSelection: onToggleSectionSelection,
                onToggleFavorite: onToggleFavorite,
                onShareItem: onShareItem,
                onTrashItem: onTrashItem
            )
            if let footerSummary {
                VStack(spacing: 4) {
                    Text(footerSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Encrypted on this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.bottom, 76)
            } else {
                Color.clear.frame(height: Self.sectionSpacing)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: GalleryWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(GalleryWidthKey.self) { width in
            // Guarded so a sub-point change (keyboard, scroll indicator) cannot cause a
            // re-layout loop.
            guard abs(width - measuredWidth) > 0.5, width > 0 else { return }
            measuredWidth = width
        }
        // Fills the viewport even when there are only one or two photos, so the grid
        // starts at the top instead of floating in the middle of the screen. The
        // content itself is never stretched: only the scroll container is.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MVColor.galleryBackground)
        // Lets the content scroll *under* the tab bar briefly while still leaving the
        // final row reachable, which is how a native photo grid behaves.
        .scrollDismissesKeyboard(.immediately)
        // Pinch changes density instead of zooming the whole grid, which keeps the
        // text crisp and avoids the blurry "scale a screenshot" look.
        .galleryPinch(density: density) { next in
            onDensityChange?(next)
        }
    }
}

/// Width of the gallery, reported out of a background GeometryReader.
private struct GalleryWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The grid itself. Split out so the width measurement above stays readable, and so
/// the columns are computed in exactly one place.
private struct LazyVGridLayout: View {
    let sections: [GallerySection]
    let density: GalleryDensity
    let spacing: CGFloat
    let isSelecting: Bool
    @Binding var selection: Set<String>
    let displayScale: CGFloat
    let measuredWidth: CGFloat
    let useAspectRatioTiles: Bool
    let onOpen: (VaultMedia) -> Void
    let onToggleSelection: (VaultMedia) -> Void
    let onToggleSectionSelection: ((GallerySection) -> Void)?
    let onToggleFavorite: ((VaultMedia) -> Void)?
    let onShareItem: ((VaultMedia) -> Void)?
    let onTrashItem: ((VaultMedia) -> Void)?

    private var columnCount: Int {
        density.columns(forWidth: measuredWidth)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: columnCount
        )
    }

    /// Edge length of one tile in points, so each cell can ask the cache for a
    /// thumbnail at the size it will actually be drawn.
    private var tileWidth: CGFloat {
        let usable = max(measuredWidth, 1) - spacing * CGFloat(columnCount - 1)
        return max(usable / CGFloat(columnCount), 1)
    }

    private var tilePixels: CGFloat {
        GalleryDensity.thumbnailPixels(tileWidth: tileWidth, displayScale: displayScale)
    }

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .center,
            spacing: spacing,
            pinnedViews: [.sectionHeaders]
        ) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        GalleryThumbCell(
                            item: item,
                            isSelecting: isSelecting,
                            isSelected: selection.contains(item.id),
                            showsAlbumBadge: !item.albumIdentifiers.isEmpty,
                            useAspectRatio: useAspectRatioTiles,
                            pixelSize: tilePixels,
                            onTap: {
                                if isSelecting {
                                    onToggleSelection(item)
                                } else {
                                    onOpen(item)
                                }
                            },
                            onSelectItem: { onToggleSelection(item) },
                            onToggleFavorite: onToggleFavorite.map { fn in { fn(item) } },
                            onShareItem: onShareItem.map { fn in { fn(item) } },
                            onTrashItem: onTrashItem.map { fn in { fn(item) } }
                        )
                    }
                } header: {
                    GallerySectionHeader(
                        section: section,
                        allSelected: !section.items.isEmpty && section.items.allSatisfy { selection.contains($0.id) },
                        onToggleSection: onToggleSectionSelection.map { fn in { fn(section) } }
                    )
                }
            }
        }
    }
}

struct GallerySectionHeader: View {
    let section: GallerySection
    var allSelected: Bool = false
    var onToggleSection: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(.headline.weight(.bold))
                if let subtitle = section.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let onToggleSection {
                Button(action: onToggleSection) {
                    Text(allSelected ? "Deselect" : "Select")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(allSelected ? "Deselect \(section.title)" : "Select \(section.title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MVColor.galleryBackground.opacity(0.95))
        .accessibilityElement(children: .contain)
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
    var useAspectRatio: Bool = false
    /// Thumbnail size requested from the cache, matched to the tile's drawn size.
    var pixelSize: CGFloat = 400
    let onTap: () -> Void
    var onSelectItem: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil
    var onShareItem: (() -> Void)? = nil
    var onTrashItem: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var didFinishLoading = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Rectangle().fill(useAspectRatio ? Color.clear : Color(.secondarySystemFill))
                if let image {
                    if useAspectRatio {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))
                            .transition(reduceMotion ? .identity : .opacity)
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                } else {
                    placeholder
                }
                if isSelecting {
                    // A soft scrim keeps the checkmark readable on a bright photo
                    // without dimming the whole library, which makes selection feel
                    // like a mode change rather than a filter.
                    Rectangle().fill(.black.opacity(0.18))
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
        .contextMenu {
            if !isSelecting {
                Button(action: onTap) {
                    Label("View", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                if let onToggleFavorite {
                    Button(action: onToggleFavorite) {
                        Label(
                            item.isFavorite ? "Unfavorite" : "Favorite",
                            systemImage: item.isFavorite ? "heart.slash" : "heart"
                        )
                    }
                }
                if let onShareItem {
                    Button(action: onShareItem) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
                if let onSelectItem {
                    Button(action: onSelectItem) {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                }
                if let onTrashItem {
                    Divider()
                    Button(role: .destructive, action: onTrashItem) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: image != nil)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .task(id: cacheKey) { await load() }
    }

    /// A density change asks for a different pixel size, which must re-run the load
    /// even though the item is the same.
    private var cacheKey: String { "\(item.id)-\(Int(pixelSize))" }

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
        } else if item.isDocument {
            Text("PDF")
                .font(.caption2.weight(.bold))
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
        let albumCount = item.albumIdentifiers.count
        if let album = item.album?.name, albumCount <= 1 {
            parts.append("Album \(album)")
        } else if albumCount > 1 {
            parts.append("In \(albumCount) albums")
        }
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
        let wanted = pixelSize
        if let cached = ThumbnailCache.shared.cachedThumbnail(for: item, pixelSize: wanted) {
            image = cached
            didFinishLoading = true
            return
        }
        let loaded = await ThumbnailCache.shared.thumbnail(for: item, pixelSize: wanted)
        guard !Task.isCancelled else { return }
        image = loaded
        didFinishLoading = true
    }
}
