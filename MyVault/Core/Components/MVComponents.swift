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
/// Small glyph overlaid on media (favorite heart, album flag, video duration).
/// Drawn with a shadow rather than a capsule so it stays legible on any photo
/// without hiding the content underneath.
struct MVBadge: View {
    let symbol: String
    var tint: Color = .white
    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

/// Progress for work the user asked for and may want to stop (import, backup,
/// restore). Cancelling is offered only when the operation can stop safely.
struct MVProgressCard: View {
    let title: String
    var detail: String?
    var progress: Double?
    var onCancel: (() -> Void)?

    var body: some View {
        MVCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(MVFont.headline)
                    Spacer(minLength: 8)
                    if let onCancel {
                        Button("Cancel", action: onCancel)
                            .font(.subheadline)
                            .accessibilityLabel("Cancel")
                    }
                }
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                } else {
                    ProgressView()
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MVInfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
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
