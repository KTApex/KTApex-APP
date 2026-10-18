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
        // Intent: lock immediately. Applied unconditionally — locking only ever removes
        // access, so it is safe even while the app is locked already.
        .onReceive(NotificationCenter.default.publisher(for: MyVaultIntentNotifications.lockVault)) { _ in
            appState.lock()
        }
        // Intent: navigate to a tab. Ignored while locked, because switching tabs behind
        // the lock screen would be invisible at best and confusing at worst; the user
        // unlocks first and the tab is then already where they asked.
        .onReceive(NotificationCenter.default.publisher(for: MyVaultIntentNotifications.openTab)) { note in
            guard appState.isUnlocked,
                  let raw = note.object as? String,
                  let tab = AppTab.fromIntentIdentifier(raw) else { return }
            appState.selectedTab = tab
        }
        // Intent: open Backup & Restore, which lives inside Settings. Same rule as the
        // document-open flow: only while unlocked, so a shortcut can never present vault
        // controls before authentication. The screen is reached by navigating to the
        // Settings tab rather than by injecting a new navigation flag, which would add
        // state to every Settings render for one entry point.
        .onReceive(NotificationCenter.default.publisher(for: MyVaultIntentNotifications.openBackup)) { _ in
            guard appState.isUnlocked else { return }
            appState.selectedTab = .settings
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
