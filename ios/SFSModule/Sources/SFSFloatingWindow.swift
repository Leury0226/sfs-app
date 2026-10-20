import Foundation
import UIKit
import Combine

// Punto de estado del boton: verde = SFS trabajando, gris = SFS apagado, rojo = sin licencia
enum SFSButtonStatus {
    case working
    case off
    case noLicense
}

// Boton flotante "SFS" estilo AssistiveTouch. Vive en una ventana propia del tamaño del boton, encima de
// Telegram: no toca la interfaz de Telegram ni la barra de estado. Se arrastra y se pega al borde mas cercano.
final class SFSFloatingWindow: UIWindow {
    private static let buttonSize: CGFloat = 58
    private static let edgeMargin: CGFloat = 8
    private static let positionKey = "sfs.floatingButton.position"

    private let buttonView = SFSFloatingButtonView()
    private var cancellables = Set<AnyCancellable>()
    private var dragStartOrigin = CGPoint.zero
    private var onTap: (() -> Void)?

    init(status: AnyPublisher<SFSButtonStatus, Never>, onTap: @escaping () -> Void) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            super.init(windowScene: scene)
        } else {
            super.init(frame: .zero)
        }

        self.onTap = onTap
        self.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        self.backgroundColor = .clear

        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        self.rootViewController = controller

        self.buttonView.frame = CGRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize)
        controller.view.addSubview(self.buttonView)

        self.buttonView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.handleTap)))
        self.buttonView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:))))

        status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.buttonView.update(status: status)
            }
            .store(in: &self.cancellables)

        self.frame = self.restoredFrame()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        self.isHidden = false
    }

    @objc private func handleTap() {
        self.onTap?()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            self.dragStartOrigin = self.frame.origin
        case .changed:
            let translation = gesture.translation(in: nil)
            self.frame.origin = CGPoint(x: self.dragStartOrigin.x + translation.x, y: self.dragStartOrigin.y + translation.y)
        case .ended, .cancelled, .failed:
            let bounds = self.screenBounds()
            let isLeft = self.frame.midX < bounds.midX
            let relativeY = bounds.height > 0 ? self.frame.midY / bounds.height : 0.4
            UserDefaults.standard.set(["isLeft": isLeft, "relativeY": relativeY], forKey: Self.positionKey)
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut], animations: {
                self.frame = self.frameFor(isLeft: isLeft, relativeY: relativeY)
            })
        default:
            break
        }
    }

    private func restoredFrame() -> CGRect {
        let saved = UserDefaults.standard.dictionary(forKey: Self.positionKey)
        let isLeft = saved?["isLeft"] as? Bool ?? false
        let relativeY = saved?["relativeY"] as? Double ?? 0.4
        return self.frameFor(isLeft: isLeft, relativeY: CGFloat(relativeY))
    }

    private func frameFor(isLeft: Bool, relativeY: CGFloat) -> CGRect {
        let bounds = self.screenBounds()
        let safeInsets = self.windowScene?.windows.first(where: { !($0 is SFSFloatingWindow) })?.safeAreaInsets ?? .zero
        let minY = safeInsets.top + Self.edgeMargin
        let maxY = bounds.height - safeInsets.bottom - Self.buttonSize - Self.edgeMargin
        let y = min(max(relativeY * bounds.height - Self.buttonSize / 2, minY), max(minY, maxY))
        let x = isLeft ? Self.edgeMargin : bounds.width - Self.buttonSize - Self.edgeMargin
        return CGRect(x: x, y: y, width: Self.buttonSize, height: Self.buttonSize)
    }

    private func screenBounds() -> CGRect {
        return self.windowScene?.coordinateSpace.bounds ?? UIScreen.main.bounds
    }
}

private final class SFSFloatingButtonView: UIView {
    private let label = UILabel()
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.backgroundColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.75)
        self.layer.borderWidth = 2
        self.layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = 0.3
        self.layer.shadowRadius = 6
        self.layer.shadowOffset = CGSize(width: 0, height: 3)

        self.label.text = "SFS"
        self.label.textColor = .white
        self.label.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        self.label.textAlignment = .center
        self.addSubview(self.label)

        self.dot.layer.borderWidth = 2
        self.dot.layer.borderColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1).cgColor
        self.addSubview(self.dot)

        self.isAccessibilityElement = true
        self.accessibilityLabel = "Abrir SFS"
        self.accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layer.cornerRadius = self.bounds.width / 2
        self.label.frame = self.bounds
        let dotSize: CGFloat = 14
        self.dot.frame = CGRect(x: self.bounds.width - dotSize - 1, y: 1, width: dotSize, height: dotSize)
        self.dot.layer.cornerRadius = dotSize / 2
    }

    func update(status: SFSButtonStatus) {
        switch status {
        case .working:
            self.dot.backgroundColor = .systemGreen
        case .off:
            self.dot.backgroundColor = .systemGray
        case .noLicense:
            self.dot.backgroundColor = .systemRed
        }
    }
}
