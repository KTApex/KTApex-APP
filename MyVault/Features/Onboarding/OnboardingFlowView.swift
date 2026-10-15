import SwiftUI

struct OnboardingPage: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let subtitle: String
}

struct OnboardingFlowView: View {
    @EnvironmentObject private var appState: AppState
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages: [OnboardingPage] = [
        OnboardingPage(symbol: "lock.shield.fill", title: "MyVault", subtitle: "Private memories.\nSpecial moments."),
        OnboardingPage(symbol: "photo.stack.fill", title: "Secure Vault", subtitle: "Keep your private photos and videos protected with real encryption."),
        OnboardingPage(symbol: "heart.fill", title: "Special Days", subtitle: "Never forget the moments that matter."),
        OnboardingPage(symbol: "faceid", title: "Face ID", subtitle: "Unlock your private vault instantly with biometrics."),
        OnboardingPage(symbol: "bell.badge.fill", title: "Notifications", subtitle: "Get reminded about important dates, on-device only.")
    ]

    var body: some View {
        VStack {
            TabView(selection: $index) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 20) {
                        Image(systemName: pages[i].symbol)
                            .font(.system(size: 84))
                            .foregroundStyle(.tint)
                            .symbolEffect(.bounce, value: index)
                            .accessibilityHidden(true)
                        Text(pages[i].title).font(MVFont.greeting).multilineTextAlignment(.center)
                        Text(pages[i].subtitle).font(MVFont.body)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(reduceMotion ? nil : .spring, value: index)

            if index < pages.count - 1 {
                MVPrimaryButton(title: "Continue") {
                    withAnimation { index += 1 }
                }
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 12) {
                    Text("You're ready.").font(MVFont.title)
                    MVPrimaryButton(title: "Get Started") {
                        Haptics.success()
                        appState.completeOnboarding()
                    }
                    .padding(.horizontal, 24)
                }
            }
            Spacer().frame(height: 24)
        }
        .accessibilityLabel("Onboarding")
    }
}
