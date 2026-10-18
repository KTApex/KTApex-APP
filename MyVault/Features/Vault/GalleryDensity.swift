import SwiftUI

/// Thumbnail size expressed as a preference, not as a number of columns.
///
/// The old control exposed "2–5 columns" directly, which meant the same setting gave
/// a four-across grid on an iPhone SE and a cramped one on a Pro Max. Density maps
/// the user's intent to a column count *for the width actually available*, so
/// "Standard" means "looks like Photos" on every device, in both orientations.
enum GalleryDensity: String, CaseIterable, Identifiable {
    case compact, standard, comfortable, large

    var id: String { rawValue }

    /// Ordered smallest to largest thumbnail; pinch steps along this.
    static var ordered: [GalleryDensity] { allCases }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .comfortable: return "Comfortable"
        case .large: return "Large"
        }
    }

    var symbol: String {
        switch self {
        case .compact: return "square.grid.4x3.fill"
        case .standard: return "square.grid.3x3.fill"
        case .comfortable: return "square.grid.2x2.fill"
        case .large: return "rectangle.grid.2x2.fill"
        }
    }

    /// Columns for a container of `width` points.
    ///
    /// Derived from a target thumbnail edge rather than from a fixed column count,
    /// so a wide landscape screen gains a column instead of stretching the same
    /// tiles, and a narrow screen keeps them readable. Clamped at 2 so a tile is
    /// always large enough to be recognisable, and at 6 so hit targets stay usable.
    func columns(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return 3 }
        let targetEdge: CGFloat
        switch self {
        case .compact: targetEdge = 64
        case .standard: targetEdge = 100
        case .comfortable: targetEdge = 138
        case .large: targetEdge = 200
        }
        let fitting = Int((width / targetEdge).rounded())
        return min(max(fitting, 2), 6)
    }

    /// Pixel size requested from `ThumbnailCache` for a tile of `tileWidth` points.
    ///
    /// Bucketed by the cache to the nearest 100 px, and capped because a 6-column
    /// tile on a 3× screen only needs ~700 px; asking for more would decrypt and
    /// downsample larger images than the cell can display.
    static func thumbnailPixels(tileWidth: CGFloat, displayScale: CGFloat) -> CGFloat {
        let wanted = max(1, tileWidth) * max(1, displayScale)
        return min(max(wanted, 200), 1200)
    }

    // MARK: - Persistence

    /// Reads the stored preference.
    ///
    /// Falls back to the old integer key (`mv.galleryColumns`, 2–5 columns) so an
    /// existing user keeps roughly the grid they had instead of being reset to the
    /// default by the upgrade.
    static func load(from defaults: UserDefaults = .standard) -> GalleryDensity {
        if let raw = defaults.string(forKey: preferencesKey), let stored = GalleryDensity(rawValue: raw) {
            return stored
        }
        switch defaults.object(forKey: legacyColumnsKey) as? Int {
        case 2: return .large
        case 4: return .comfortable
        case 5: return .compact
        default: return .standard
        }
    }

    static func save(_ density: GalleryDensity, to defaults: UserDefaults = .standard) {
        defaults.set(density.rawValue, forKey: preferencesKey)
        // Keep the legacy key truthful for the backup manifest, which still reads it.
        defaults.set(density.columns(forWidth: 390), forKey: legacyColumnsKey)
    }

    static let preferencesKey = "mv.galleryDensity"
    static let legacyColumnsKey = "mv.galleryColumns"

    /// Neighbour in the ordered list, for pinch and the segmented control.
    func stepped(by delta: Int) -> GalleryDensity {
        let all = GalleryDensity.ordered
        guard let current = all.firstIndex(of: self) else { return self }
        let next = min(max(current + delta, 0), all.count - 1)
        return all[next]
    }
}

/// Pinch-to-change-density.
///
/// Applied to the grid's scroll view. The threshold is per-step rather than
/// continuous: a pinch that crosses it changes density once and then waits for the
/// finger to come back, so one gesture cannot race through four densities. It also
/// never fires on a two-finger scroll that happens to scale slightly, which is the
/// usual way an unguarded MagnifyGesture annoys users in a photo grid.
struct GalleryPinchGesture: ViewModifier {
    let density: GalleryDensity
    let onChange: (GalleryDensity) -> Void

    @GestureState private var pinchScale: CGFloat = 1
    @State private var stepped = false

    /// How much magnification a single step needs.
    private static let stepThreshold: CGFloat = 0.22

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture()
                .updating($pinchScale) { value, state, _ in state = value.magnification }
                .onChanged { value in
                    guard !stepped else { return }
                    guard abs(value.magnification - 1) >= Self.stepThreshold else { return }
                    stepped = true
                    // Spreading the fingers (magnification > 1) makes tiles bigger,
                    // which means fewer columns — one step towards `.large`.
                    let delta = value.magnification > 1 ? 1 : -1
                    let next = density.stepped(by: delta)
                    guard next != density else { return }
                    Haptics.selection()
                    onChange(next)
                }
                .onEnded { _ in stepped = false }
        )
    }
}

extension View {
    func galleryPinch(density: GalleryDensity, onChange: @escaping (GalleryDensity) -> Void) -> some View {
        modifier(GalleryPinchGesture(density: density, onChange: onChange))
    }
}
