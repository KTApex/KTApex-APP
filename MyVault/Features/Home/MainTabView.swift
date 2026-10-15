import SwiftUI
import SwiftData

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }.tag(AppTab.home)
            VaultView().tabItem { Label("Vault", systemImage: "lock.shield.fill") }.tag(AppTab.vault)
            SpecialDaysView().tabItem { Label("Special Days", systemImage: "heart.fill") }.tag(AppTab.specialDays)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(AppTab.settings)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appState.selectedTab)
    }
}
