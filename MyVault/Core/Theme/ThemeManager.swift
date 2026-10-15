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
}

struct MVColors {
    static let cardGradientLight = [Color.white, Color(.systemGray6)]
    static let cardGradientDark = [Color(.systemGray6).opacity(0.35), Color.black.opacity(0.2)]
}
struct MVRadius { static let s: CGFloat = 10; static let m: CGFloat = 16; static let l: CGFloat = 24 }
struct MVShadow {
    static func card(_ colorScheme: ColorScheme) -> Color { colorScheme == .dark ? .black.opacity(0.5) : .black.opacity(0.08) }
}
