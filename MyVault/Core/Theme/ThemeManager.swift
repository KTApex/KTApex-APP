import SwiftUI

enum AppThemeMode: String, CaseIterable { case system, light, dark }
enum AppAccent: String, CaseIterable, Identifiable {
    case blue, purple, pink, green, orange
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .blue: return .blue; case .purple: return .purple; case .pink: return .pink
        case .green: return .green; case .orange: return .orange
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    /// The one instance the app runs on. A restore needs to reach the live
    /// manager, not a freshly created one, or the new theme would only appear
    /// after a relaunch.
    static let shared = ThemeManager()

    @Published var mode: AppThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mv.theme"); }
    }
    @Published var accent: AppAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "mv.accent"); }
    }
    init() {
        mode = AppThemeMode(rawValue: UserDefaults.standard.string(forKey: "mv.theme") ?? "system") ?? .system
        accent = AppAccent(rawValue: UserDefaults.standard.string(forKey: "mv.accent") ?? "blue") ?? .blue
    }
    var colorScheme: ColorScheme? {
        switch mode { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
    var accentColorValue: Color { accent.color }

    /// Applies preferences carried in from a backup. Setting the properties
    /// persists them through the observers above and publishes the change, so
    /// the restored theme takes effect immediately. Unknown values are ignored.
    func applyRestoredPreferences(theme: String?, accent: String?) {
        if let theme, let mode = AppThemeMode(rawValue: theme) { self.mode = mode }
        if let accent, let restored = AppAccent(rawValue: accent) { self.accent = restored }
    }
}

struct MVColors {
    static let cardGradientLight = [Color.white, Color(.systemGray6)]
    static let cardGradientDark = [Color(.systemGray6).opacity(0.35), Color.black.opacity(0.2)]
}

/// Semantic colours for the vault surfaces.
///
/// The gallery deliberately uses the system grouped-background colours so it tracks
/// Light/Dark mode and the elevated-surface treatment the user expects, while the
/// media viewer uses a near-black that never changes with the system — a photo
/// should be judged against a constant backdrop, exactly as a private vault should
/// not reveal the app's chrome behind its media.
enum MVColor {
    /// Backdrop for the full-screen media viewer. Fixed, not `.black`, so it reads
    /// as a deliberate surface rather than a void.
    static let viewerBackground = Color(red: 0.04, green: 0.04, blue: 0.05)

    /// Gallery background: grouped system background in both appearances.
    static let galleryBackground = Color(.systemGroupedBackground)

    /// Thin separator used between gallery sections.
    static let hairline = Color(.separator).opacity(0.5)
}
struct MVRadius { static let s: CGFloat = 10; static let m: CGFloat = 16; static let l: CGFloat = 24 }
struct MVShadow {
    static func card(_ colorScheme: ColorScheme) -> Color { colorScheme == .dark ? .black.opacity(0.5) : .black.opacity(0.08) }
}
