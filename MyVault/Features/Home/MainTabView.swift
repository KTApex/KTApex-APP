import SwiftUI
import SwiftData

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(AppTab.home)
            VaultView().tabItem { Label("Vault", systemImage: "lock.shield.fill") }.tag(AppTab.vault)
            SpecialDaysView().tabItem { Label("Special Days", systemImage: "heart.fill") }.tag(AppTab.specialDays)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(AppTab.settings)
        }
        // Tab switching is a cross-fade only. A spring here animates the whole tab
        // container, which makes the tab bar itself appear to shift while the
        // selected item changes; an opacity transition is stable and honours
        // Reduce Motion by simply being instant.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: appState.selectedTab)
    }
}
