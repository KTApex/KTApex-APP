import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        Group {
            if !appState.onboardingCompleted { OnboardingFlowView() }
            else if !appState.isUnlocked { LockScreenView() }
            else { MainTabView() }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: appState.onboardingCompleted)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: appState.isUnlocked)
        .onReceive(NotificationCenter.default.publisher(for: .didOpenSpecialDayNotification)) { note in
            guard let id = note.object as? String else { return }
            appState.openSpecialDay(id: id)
        }
    }
}
