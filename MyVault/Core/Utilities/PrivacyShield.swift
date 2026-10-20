import UIKit

/// App-switcher privacy shield: presents a blurred cover window while the app
/// is inactive or backgrounded, or during screen recording, so OS snapshots and
/// captures never reveal private media.
final class PrivacyShield {
    static let shared = PrivacyShield()
    private var window: UIWindow?
    private init() {}

    func showShield() {
        guard window == nil else { return }
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        let w: UIWindow
        if let activeScene {
            w = UIWindow(windowScene: activeScene)
            w.frame = activeScene.coordinateSpace.bounds
        } else {
            w = UIWindow(frame: UIScreen.main.bounds)
        }
        w.windowLevel = .alert + 1

        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.frame = w.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(blur)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .semibold)
        icon.tintColor = .label

        let label = UILabel()
        label.text = "MyVault"
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textColor = .label

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        vc.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor)
        ])

        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
    }

    func hideShield() {
        window?.isHidden = true
        window = nil
    }
}
