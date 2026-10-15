import UIKit
/// App-switcher privacy shield: presents a blurred cover window while the app
/// is backgrounded so the OS snapshot never reveals private media.
final class PrivacyShield {
    static let shared = PrivacyShield()
    private var window: UIWindow?
    private init() {}
    func showShield() {
        guard window == nil else { return }
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.windowLevel = .alert + 1
        let vc = UIViewController(); vc.view.backgroundColor = .systemBackground
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial)); blur.frame = w.bounds; blur.autoresizingMask = [.flexibleWidth,.flexibleHeight]
        vc.view.addSubview(blur)
        let label = UILabel(); label.text = "🔒 MyVault"; label.font = .systemFont(ofSize: 28, weight: .bold); label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label); NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor), label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor)])
        w.rootViewController = vc; w.makeKeyAndVisible(); window = w
    }
    func hideShield() { window?.isHidden = true; window = nil }
}
