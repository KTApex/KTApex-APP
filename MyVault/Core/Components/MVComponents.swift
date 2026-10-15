import SwiftUI

struct MVPrimaryButton: View {
    let title: String; let action: () -> Void
    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            Text(title).font(MVFont.headline).frame(maxWidth: .infinity).padding()
                .background(.tint).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: MVRadius.m))
        }.accessibilityLabel(title)
    }
}
struct MVCard<Content: View>: View {
    @Environment(\.colorScheme) var cs
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: MVRadius.m))
            .shadow(color: MVShadow.card(cs), radius: 12, y: 4)
    }
}
struct MVEmptyState: View {
    let symbol: String; let title: String; let subtitle: String; var actionTitle: String?; var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(.tint).symbolEffect(.bounce, value: title)
            Text(title).font(MVFont.title); Text(subtitle).font(MVFont.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let a = actionTitle { Button(a) { Haptics.tap(); action?() }.buttonStyle(.borderedProminent) }
        }.padding(32).accessibilityElement(children: .combine)
    }
}
struct MVLoadingView: View {
    let message: String
    var body: some View { VStack(spacing: 12) { ProgressView(); Text(message).foregroundStyle(.secondary) }.padding() }
}
struct CountdownRing: View {
    var progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 8)
            Circle().trim(from: 0, to: min(max(progress,0),1)).stroke(Color.accentColor, style: .init(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90)).animation(.spring, value: progress)
        }
    }
}
