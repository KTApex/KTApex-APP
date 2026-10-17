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
        // A backup the user opened from Files. Presented only from here, and only once
        // the vault is unlocked, so a document open can never skip the lock screen.
        // `item:` keeps the request alive for the lifetime of the sheet and clears it
        // (plus its scratch copy) on dismissal.
        .sheet(item: backupOpenBinding) { pending in
            // `BackupRestoreView` is normally pushed by Settings and owns no
            // NavigationStack of its own, so the sheet supplies one — otherwise its
            // title and Done button would have nowhere to render.
            NavigationStack {
                BackupRestoreView(openingExternal: pending)
            }
            .environmentObject(appState)
        }
        // A document that could not even be staged is reported instead of the tap
        // appearing to do nothing.
        .alert("Could not open backup", isPresented: documentErrorBinding) {
            Button("OK", role: .cancel) { appState.documentOpenError = nil }
        } message: {
            Text(appState.documentOpenError ?? "")
        }
    }

    /// Only non-nil while unlocked: if the app is locked the request stays parked on
    /// `AppState` and surfaces the moment authentication succeeds.
    private var backupOpenBinding: Binding<PendingBackupOpen?> {
        Binding(
            get: { appState.isUnlocked ? appState.pendingBackupOpen : nil },
            set: { if $0 == nil { appState.clearPendingBackupOpen() } }
        )
    }

    private var documentErrorBinding: Binding<Bool> {
        Binding(
            get: { appState.documentOpenError != nil },
            set: { if !$0 { appState.documentOpenError = nil } }
        )
    }
}
